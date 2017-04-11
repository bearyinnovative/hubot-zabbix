# Description:
#   Integration with Zabbix
#
# Configuration:
#   HUBOT_ZABBIX_USER
#   HUBOT_ZABBIX_PASSWORD
#   HUBOT_ZABBIX_ENDPOINT
#   HUBOT_ZABBIX_MIN_SEVERITY
#
# Commands:
#   hubot auth to zabbix - let hubot to re-logging in to zabbix
#   hubot zabbix events - list all active zabbix events
#   hubot zabbix events on <hostname> - list active events on host
#   hubot zabbix events of <hostgroup> - list active events on hostgroup
#   hubot zabbix events sort by [severity|time|hostname] - list active events sorted by given key (available on all `events` command)
#   hubot zabbix graphs <regexp> on <hostname> [@<period>] - list graphs like <keyword> on <hostname>
#   hubot zabbix graphs <regexp> of <hostgroup> [@<period>] - list graphs like <keyword> of <hostgroup>
#

crypto = require 'crypto'
util = require 'util'
moment = require 'moment'
AWS = require 'aws-sdk'
REQ = require 'request'
rp = require 'request-promise'

module.exports = (robot) ->
  s3_bucket = process.env.HUBOT_ZABBIX_S3_BUCKET
  s3_access_key = process.env.HUBOT_ZABBIX_S3_ACCESS_KEY
  s3_secret_key = process.env.HUBOT_ZABBIX_S3_SECRET_KEY
  s3_region = process.env.HUBOT_ZABBIX_S3_REGION
  url = process.env.HUBOT_ZABBIX_ENDPOINT.replace(/\/$/,'')
  rpcUrl = "#{url}/api_jsonrpc.php"

  cookie_jar = REQ.jar()

  ##### Request methods

  request_ = (method, params, callback) ->
    payload = {
      jsonrpc: "2.0",
      method: method,
      params: params,
      id: 1
    }

    robot.logger.info payload
    payload.auth = token if token

    robot.logger.debug("Zabbix #{method} <- #{util.inspect(params)}")
    robot.http(rpcUrl)
      .header('Content-Type', 'application/json')
      .post(JSON.stringify(payload)) (err, res, body) ->
        robot.logger.info("Zabbix #{method} -> #{body}")
        callback JSON.parse(body), err, res, body

  request = (msg, method, params, callback) ->
    request_(method, params, (json, err, res, body) ->
      if json.error
        msg.send("ERR: #{util.inspect(res.error)}") if msg
        return
      callback(json, err, res, body)
    )

  ##### Authenticate methods

  token = null
  getToken = (callback) ->
    token = null
    credential = {
      user: process.env.HUBOT_ZABBIX_USER,
      password: process.env.HUBOT_ZABBIX_PASSWORD,
    }

    robot.logger.info "Logging in to zabbix: #{url}"
    request_('user.login', credential, (res) ->
      if res.error
        robot.logger.error "Zabbix auth failed: #{util.inspect(res)}"
        callback(res.error) if callback
      else
        robot.logger.info  "Zabbix auth succeeded"
        token = res.result
        callback(null) if callback
    )

  setInterval((-> getToken()), 60 * 60 * 1000)

  ##### Image caching

  imageStorage = {}
  imageStorageKeys = []
  hubotUrl = process.env.HUBOT_URL || process.env.HEROKU_URL || "http://localhost:#{process.env.PORT || 8080}"
  hubotUrl = hubotUrl.replace(/\/$/,'')

  hubotCachesImage = process.env.HUBOT_CACHE_IMAGE

  fetchImage = (url) ->
    options =
      uri: url
      encoding: null
      jar: cookie_jar
    rp options

  processImage = (msg,text,body) ->
    postURL = getS3SignedPUTURL()
    S3ImgURL = postURL.substring(0,postURL.indexOf('?'))
    console.log S3ImgURL
    uploadToS3(postURL,body).then(
      (response) ->
        sendBack msg,text,S3ImgURL)

  getS3SignedPUTURL = () ->
    AWS.config.update {"accessKeyId" : s3_access_key, "secretAccessKey" : s3_secret_key}
    AWS.config.update {"region": s3_region}
    s3 = new AWS.S3 {params : {Bucket : s3_bucket}}

    # generate random filename
    filename = "#{crypto.randomBytes(20).toString('hex')}.png"
    imageData = {Key: filename, ACL: 'public-read', ContentType: 'image/png'}
    postURL = s3.getSignedUrl 'putObject', imageData;
    postURL

  uploadToS3 = (url,content) ->
    options =
      method: 'PUT'
      uri: url
      body: content
      headers:
        'Content-Type': 'image/png'
    rp options

  sendBack = (response,text,imgURL) ->
    console.log text
    images = [{'url': imgURL}]
    markdownTitle = url
    attachments = [{'title':'','text' :'', 'color'  : 'green','images' : images}]
    opts = {markdown:true, attachments:attachments}
    response.send  markdownTitle, opts

  getImageURL = (msg,filter,graphid, period) ->
    #return callback(url) unless hubotCachesImage

    period = 3600 unless period
    cookie = "zbx_sessionid=#{token}"
    imageURL = "#{url}/chart2.php?graphid=#{graphid}&period=#{period}&width=497#.png"

    cookie_jar.setCookie(cookie,url)

    robot.logger.info "Caching #{imageURL} #{cookie}"


    fetchImage(imageURL).then(
      (response) ->
        processImage(msg,filter, response))


  robot.router.get '/zbximg/:key', (req, res) ->
    cached = imageStorage[req.params.key]
    if cached
      res.set('Content-Type', cached.type)
      res.send(cached.body)
    else
      res.status(404)
      res.send('404')

  ##### Misc

  parsePeriodStr = (str) ->
    sec = 0

    if str && str != ""
      parts = str.match(/(?:(\d+)([dhms]?))/gi)
      for part in parts
        match = part.match(/(\d+)([dhms])?$/i)
        num = parseInt(match[1], 10)
        mod = match[2]?.toLowerCase()

        switch mod
          when 'd' then sec += 60 * 60 * 24 * num
          when 'h' then sec += 60 * 60 * num
          when 'm' then sec += 60 * num
          when 's' then sec += num
          else sec += num

    if sec == 0
      sec = 3600

    sec

  getHostgroups = (msg, filter, callback) ->
    params = {
      output: 'extend',
      filter: {name: filter}
    }
    request msg, 'hostgroup.get', params, callback

  ##### Utilities

  SEVERITY_STRINGS = {
    0: 'Not classified',
    1: 'info',
    2: 'warn',
    3: 'avg',
    4: 'HIGH',
    5: 'DISASTER'
  }

  stringSeverity = (val) ->
    i = parseInt(val, 10)
    SEVERITY_STRINGS[i] || i.toString()

  ##### Bootstrap

  getToken()

  ##### Responders

  robot.respond /(?:auth(?:enticate)?|log\s*in)\s+(?:to\s+)?zabbix/i, (msg) ->
    getToken (error) ->
      if error
        msg.send("I couldn't log in Zabbix: #{util.inspect(error)}")
      else
        msg.send("Logged in to zabbix!")

  # zabbix (list) events (on host|for group) (sort(ed) by <key> (asc|desc))
  robot.respond /(?:(?:zabbix|zbx)\s+(?:list\s+)?(?:event|alert)s?(?:\s+(on|of|for)\s+([^\s]+))?(?:\s+sort(?:ed)?\s+by\s+(.+?)(?:\s+(asc|desc)))?)/i, (msg) ->
    params = {
      output: 'extend',
      only_true: true,
      selectHosts: 'extend',
      selectLastEvent: 'extend',
      expandDescription: true,
      min_severity: process.env.HUBOT_ZABBIX_MIN_SEVERITY || 2,
      monitored: true
    }

    hostFilter = null
    if msg.match[1] == 'on'
# NOTE: params.host seems not working (it requires hostIds?)
      hostFilter = msg.match[2]
    else if msg.match[1] == 'of' || msg.match[1] == 'for'
      params.group = msg.match[2]

    if msg.match[3]
      params.sortfield = for key in msg.match[3].split(/,/)
        {
          severity: 'priority',
          time: 'lastchange',
          host: 'hostname',
          name: 'hostname',
          id: 'triggerid'
        }[msg.match[3]] || msg.match[3]
      params.sortorder = for key in msg.match[4].split(/,/)
        {asc: 'ASC', desc: 'DESC', DESC: 'DESC', ASC: 'ASC'}[key]
    else
      params.sortfield = ['lastchange', 'priority']
      params.sortorder = ['DESC', 'DESC']

    request msg, 'trigger.get', params, (res) ->
      lines = for trigger in res.result
        event = trigger.lastEvent
        time = moment.unix(event.clock).fromNow()
        (for host in trigger.hosts
          continue if hostFilter && hostFilter != host.name
          continue if event.value == '0' || event.value == 0
          if host.maintenance_status == 1 || host.maintenance_status == '1'
            maintenance = '☃'
          else
            maintenance = ''
          "* #{maintenance}#{host.name} (#{stringSeverity(trigger.priority)}): #{trigger.description} (#{time})"
        ).join("\n")
      msg.send lines.join("\n").replace(/\n+/g,"\n")


  # zabbix list graphs on <hostname>
  robot.respond /(?:(?:zabbix|zbx)\s+(?:list\s+)?graphs?\s+(?:(?:on|of|for)\s+)?(.+))/i, (msg) ->
    console.log msg.match[1]
    params = {
      output: 'extend',
      expandName: true,
      filter: {host: msg.match[1]}
    }

    request msg, 'graph.get', params, (res) ->
      response = (for graph in res.result
        "- #{graph.name}"
      ).join("\n")

      msg.send response

  # zabbix graph <filter> on <hostname>
  robot.respond /(?:zabbix|zbx)\s+graphs?\s+(.+)\s+(on|of)\s+(.+?)(?:\s+@(.+))?$/i, (msg) ->
    filter = new RegExp(msg.match[1], 'i')
    host = msg.match[3]
    periodStr = msg.match[4]

    respond = ((hostgroups) =>
      if hostgroups
        params = {
          output: 'extend',
          selectHosts: true,
          expandName: true,
          groupids: (group.groupid for group in hostgroups)
        }
        msg.send("Graphs of #{(group.name for group in hostgroups).join(',')} (filter: #{msg.match[1]})")
      else
        params = {
          output: 'extend',
          expandName: true,
          filter: {host: host}
        }
        msg.send("Graphs on #{host} (filter: #{msg.match[1]})")

      request msg, 'graph.get', params, (res) ->
        for graph in res.result
          continue unless graph.name.match(filter)
          getImageURL(msg,filter, graph.graphid, parsePeriodStr(periodStr))
    )

    switch msg.match[2]
      when "on"
        respond(null)
      when "of"
        getHostgroups(msg, host, (res) => respond(res.result))
