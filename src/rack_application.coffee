# The `RackApplication` class is responsible for managing a
# [Nack](http://josh.github.com/nack/) server for a given Rack
# application. Incoming HTTP requests are dispatched to
# `RackApplication` instances by an `HttpServer`, where they are
# subsequently handled by a pool of Nack worker processes. By default,
# Pow tells Nack to use a maximum of two worker processes per
# application, but this can be overridden with the configuration's
# `workers` option.
#
# Before creating the Nack server, Pow executes the `.powrc` and
# `.powenv` scripts if they're present in the application root,
# captures their environment variables, and passes them along to the
# Nack worker processes. This lets you modify your `RUBYOPT` to use
# different Ruby options, for example.
#
# If [rvm](http://rvm.beginrescueend.com/) is installed and an
# `.rvmrc` file is present in the application's root, Pow will load
# both before creating the Nack server. This makes it easy to run an
# app with a specific version of Ruby.
#
# Nack workers remain running until they're killed, restarted (by
# touching the `tmp/restart.txt` file in the application root), or
# until the application has not served requests for the length of time
# specified in the configuration's `timeout` option (15 minutes by
# default).

async = require "async"
fs    = require "fs"
nack  = require "nack"

{bufferLines, pause, sourceScriptEnv} = require "./util"
{join, exists, basename} = require "path"

module.exports = class RackApplication
  # Create a `RackApplication` for the given configuration and
  # root path. The application begins life in the uninitialized
  # state.
  constructor: (@configuration, @root) ->
    @logger = @configuration.getLogger join "apps", basename @root
    @debugLog = @configuration.getLogger "debug"
    @readyCallbacks = []

  debug: (req, message) ->
    if message
      message = "[#{req.method} #{req.headers.host} #{req.url}] #{message}"
    else
      message = req

    name = "RackApplication"
    name = "#{name}(#{@state})" if @state
    @debugLog.debug "#{name} #{message}"

  # Invoke `callback` if the application's state is ready. Otherwise,
  # queue the callback to be invoked when the application becomes
  # ready, then start the initialization process.
  ready: (callback) ->
    if @state is "ready"
      callback()
    else
      @readyCallbacks.push callback
      @initialize()

  # Collect environment variables from `.powrc` and `.powenv`, in that
  # order, if present. The idea is that `.powrc` files can be checked
  # into a source code repository for global configuration, leaving
  # `.powenv` free for any necessary local overrides.
  loadScriptEnvironment: (env, callback) ->
    async.reduce [".powrc", ".powenv"], env, (env, filename, callback) =>
      exists script = join(@root, filename), (scriptExists) ->
        if scriptExists
          sourceScriptEnv script, env, callback
        else
          callback null, env
    , callback

  # If `.rvmrc` and `$HOME/.rvm/scripts/rvm` are present, load rvm,
  # source `.rvmrc`, and invoke `callback` with the resulting
  # environment variables. If `.rvmrc` is present but rvm is not
  # installed, invoke `callback` with an informative error message.
  loadRvmEnvironment: (env, callback) ->
    exists script = join(@root, ".rvmrc"), (rvmrcExists) =>
      if rvmrcExists
        exists rvm = @configuration.rvmPath, (rvmExists) ->
          if rvmExists
            before = "source '#{rvm}' > /dev/null"
            sourceScriptEnv script, env, {before}, callback
          else
            callback Error ".rvmrc present but rvm (#{rvm}) not found"
      else
        callback null, env

  # Load the application's full environment from `.powrc`, `.powenv`,
  # and `.rvmrc`.
  loadEnvironment: (callback) ->
    @loadScriptEnvironment null, (err, env) =>
      if err then callback err
      else @loadRvmEnvironment env, (err, env) =>
        if err then callback err
        else callback null, env

  # Begin the initialization process if the application is in the
  # uninitialized state.
  initialize: ->
    return if @state
    @state = "initializing"
    @debug "initialize"

    # Load the application's environment. If an error is raised or
    # either of the environment scripts exits with a non-zero status,
    # reset the application's state and log the error.
    @loadEnvironment (err, env) =>
      @debug "loaded environment"

      if err
        @state = null
        @debug "error: #{err.message}"
        @logger.error err.message
        @logger.error "stdout: #{err.stdout}"
        @logger.error "stderr: #{err.stderr}"

      # Set the application's state to ready. Then create the Nack
      # server instance using the `workers` and `timeout` options from
      # the application's configuration.
      else
        @state = "ready"

        @server = nack.createServer join(@root, "config.ru"),
          env:  env
          size: @configuration.workers
          idle: @configuration.timeout

        @debug "nack server created"

        #  Log the workers' stderr and stdout, and log each worker's
        #  PID as it spawns and exits.
        bufferLines @server.pool.stdout, (line) => @logger.info line
        bufferLines @server.pool.stderr, (line) => @logger.warning line

        @server.pool.on "worker:spawn", (process) =>
          @logger.debug "nack worker #{process.child.pid} spawned"

        @server.pool.on "worker:exit", (process) =>
          @logger.debug "nack worker exited"

      # Invoke and remove all queued callbacks, passing along the
      # error, if any.
      readyCallback err for readyCallback in @readyCallbacks
      @debug "invoked #{@readyCallbacks.length} ready callbacks"
      @readyCallbacks = []

  # Handle an incoming HTTP request. Wait until the application is in
  # the ready state, restart the workers if necessary, then pass the
  # request along to the Nack server.
  handle: (req, res, next, callback) ->
    @debug req, "handle"
    resume = pause req

    @ready (err) =>
      return next err if err
      @restartIfNecessary =>
        req.proxyMetaVariables =
          SERVER_PORT: @configuration.dstPort.toString()
        try
          @debug req, "passing request to nack"
          @server.handle req, res, next
        finally
          resume()
          callback?()

  # Terminate any running Nack workers and invoke the given callback
  # when they exit.
  quit: (callback) ->
    @debug "quit"
    if @state is "ready"
      @server.pool.once "exit", callback if callback
      @server.pool.quit()
    else
      callback?()

  # Terminate any running Nack workers if `tmp/restart.txt` has been
  # modified since the last call to this function, and invoke the
  # given callback when they exit.
  restartIfNecessary: (callback) ->
    @debug "restartIfNecessary"
    fs.stat join(@root, "tmp/restart.txt"), (err, stats) =>
      if not err and stats?.mtime isnt @mtime
        @debug "restarting"
        @quit callback
      else
        callback()
      @mtime = stats?.mtime
