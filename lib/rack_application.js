(function() {
  var RackApplication, async, basename, bufferLines, exists, fs, join, nack, pause, sourceScriptEnv, _ref, _ref2;
  var __bind = function(fn, me){ return function(){ return fn.apply(me, arguments); }; };
  async = require("async");
  fs = require("fs");
  nack = require("nack");
  _ref = require("./util"), bufferLines = _ref.bufferLines, pause = _ref.pause, sourceScriptEnv = _ref.sourceScriptEnv;
  _ref2 = require("path"), join = _ref2.join, exists = _ref2.exists, basename = _ref2.basename;
  module.exports = RackApplication = (function() {
    function RackApplication(configuration, root) {
      this.configuration = configuration;
      this.root = root;
      this.logger = this.configuration.getLogger(join("apps", basename(this.root)));
      this.debugLog = this.configuration.getLogger("debug");
      this.readyCallbacks = [];
    }
    RackApplication.prototype.debug = function(req, message) {
      var name;
      if (message) {
        message = "[" + req.method + " " + req.headers.host + " " + req.url + "] " + message;
      } else {
        message = req;
      }
      name = "RackApplication";
      if (this.state) {
        name = "" + name + "(" + this.state + ")";
      }
      return this.debugLog.debug("" + name + " " + message);
    };
    RackApplication.prototype.ready = function(callback) {
      if (this.state === "ready") {
        return callback();
      } else {
        this.readyCallbacks.push(callback);
        return this.initialize();
      }
    };
    RackApplication.prototype.loadScriptEnvironment = function(env, callback) {
      return async.reduce([".powrc", ".powenv"], env, __bind(function(env, filename, callback) {
        var script;
        return exists(script = join(this.root, filename), function(scriptExists) {
          if (scriptExists) {
            return sourceScriptEnv(script, env, callback);
          } else {
            return callback(null, env);
          }
        });
      }, this), callback);
    };
    RackApplication.prototype.loadRvmEnvironment = function(env, callback) {
      var script;
      return exists(script = join(this.root, ".rvmrc"), __bind(function(rvmrcExists) {
        var rvm;
        if (rvmrcExists) {
          return exists(rvm = this.configuration.rvmPath, function(rvmExists) {
            var before;
            if (rvmExists) {
              before = "source '" + rvm + "' > /dev/null";
              return sourceScriptEnv(script, env, {
                before: before
              }, callback);
            } else {
              return callback(Error(".rvmrc present but rvm (" + rvm + ") not found"));
            }
          });
        } else {
          return callback(null, env);
        }
      }, this));
    };
    RackApplication.prototype.loadEnvironment = function(callback) {
      return this.loadScriptEnvironment(null, __bind(function(err, env) {
        if (err) {
          return callback(err);
        } else {
          return this.loadRvmEnvironment(env, __bind(function(err, env) {
            if (err) {
              return callback(err);
            } else {
              return callback(null, env);
            }
          }, this));
        }
      }, this));
    };
    RackApplication.prototype.initialize = function() {
      if (this.state) {
        return;
      }
      this.state = "initializing";
      this.debug("initialize");
      return this.loadEnvironment(__bind(function(err, env) {
        var readyCallback, _i, _len, _ref;
        this.debug("loaded environment");
        if (err) {
          this.state = null;
          this.debug("error: " + err.message);
          this.logger.error(err.message);
          this.logger.error("stdout: " + err.stdout);
          this.logger.error("stderr: " + err.stderr);
        } else {
          this.state = "ready";
          this.server = nack.createServer(join(this.root, "config.ru"), {
            env: env,
            size: this.configuration.workers,
            idle: this.configuration.timeout
          });
          this.debug("nack server created");
          bufferLines(this.server.pool.stdout, __bind(function(line) {
            return this.logger.info(line);
          }, this));
          bufferLines(this.server.pool.stderr, __bind(function(line) {
            return this.logger.warning(line);
          }, this));
          this.server.pool.on("worker:spawn", __bind(function(process) {
            return this.logger.debug("nack worker " + process.child.pid + " spawned");
          }, this));
          this.server.pool.on("worker:exit", __bind(function(process) {
            return this.logger.debug("nack worker exited");
          }, this));
        }
        _ref = this.readyCallbacks;
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          readyCallback = _ref[_i];
          readyCallback(err);
        }
        this.debug("invoked " + this.readyCallbacks.length + " ready callbacks");
        return this.readyCallbacks = [];
      }, this));
    };
    RackApplication.prototype.handle = function(req, res, next, callback) {
      var resume;
      this.debug(req, "handle");
      resume = pause(req);
      return this.ready(__bind(function(err) {
        if (err) {
          return next(err);
        }
        return this.restartIfNecessary(__bind(function() {
          req.proxyMetaVariables = {
            SERVER_PORT: this.configuration.dstPort.toString()
          };
          try {
            this.debug(req, "passing request to nack");
            return this.server.handle(req, res, next);
          } finally {
            resume();
            if (typeof callback == "function") {
              callback();
            }
          }
        }, this));
      }, this));
    };
    RackApplication.prototype.quit = function(callback) {
      this.debug("quit");
      if (this.state === "ready") {
        if (callback) {
          this.server.pool.once("exit", callback);
        }
        return this.server.pool.quit();
      } else {
        return typeof callback == "function" ? callback() : void 0;
      }
    };
    RackApplication.prototype.restartIfNecessary = function(callback) {
      this.debug("restartIfNecessary");
      return fs.stat(join(this.root, "tmp/restart.txt"), __bind(function(err, stats) {
        if (!err && (stats != null ? stats.mtime : void 0) !== this.mtime) {
          this.debug("restarting");
          this.quit(callback);
        } else {
          callback();
        }
        return this.mtime = stats != null ? stats.mtime : void 0;
      }, this));
    };
    return RackApplication;
  })();
}).call(this);
