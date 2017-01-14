({
  requires: [
    { "import-type": "builtin", name: "runtime-lib" }
  ],
  nativeRequires: ["pyret-base/js/secure-loader"],
  provides: {},
  theModule: function(runtime, namespace, uri, runtimeLib, loader) {
    var EXIT_SUCCESS = 0;
    var EXIT_ERROR = 1;
    var EXIT_ERROR_RENDERING_ERROR = 2;
    var EXIT_ERROR_DISPLAYING_ERROR = 3;
    var EXIT_ERROR_CHECK_FAILURES = 4;
    var EXIT_ERROR_JS = 5;
    var EXIT_ERROR_UNKNOWN = 6;


    var brandModule = runtime.namedBrander("module", ["load-lib: module brander"]);
    var brandModuleResult = runtime.namedBrander("module-result", ["load-lib: module-result brander"]);
    var brandRealm = runtime.namedBrander("realm", ["load-lib: realm brander"]);

    var annModule = runtime.makeBranderAnn(brandModule, "Module");
    var annModuleResult = runtime.makeBranderAnn(brandModuleResult, "ModuleResult");
    var annRealm = runtime.makeBranderAnn(brandRealm, "Realm");

    function applyBrand(brand, val) {
      return runtime.getField(brand, "brand").app(val);
    }

    function makeRealm(dynamicModules) {
      return applyBrand(brandRealm, runtime.makeObject({
        "realm": runtime.makeOpaque(dynamicModules)
      }));
    }

    function emptyRealm() {
      return applyBrand(brandRealm, runtime.makeObject({
        "realm": runtime.makeOpaque({})
      }));
    }

    function makeModule(runtimeForModule, moduleFun, namespace) {
      var m = runtime.makeOpaque({
        runtime: runtimeForModule,
        moduleFun: moduleFun,
        namespace: namespace
      });
      return m;
    }

    function makeModuleResult(runtimeForModule, result, realm, compileResult) {
      return runtime.makeOpaque({
        runtime: runtimeForModule,
        result: result,
        realm: realm,
        compileResult: compileResult
      });
    }

    function checkSuccess(mr, field) {
      if(!mr.val) {
        console.error(mr);
        runtime.ffi.throwMessageException("Tried to get " + field + " of non-successful module compilation.");
      }
      if(!(mr.val.runtime.isSuccessResult(mr.val.result))) {
        console.error(mr.val.result);
        console.error(mr.val.result.exn);
        runtime.ffi.throwMessageException("Tried to get " + field + " of non-successful module execution.");
      }
    }
    function isSuccessResult(mr) {
      return mr.val.runtime.isSuccessResult(mr.val.result);
    }
    function isFailureResult(mr) {
      return mr.val.runtime.isFailureResult(mr.val.result);
    }
    function isPrimitive(rt, ans) {
      return rt.isNumber(ans) || rt.isString(ans) || rt.isBoolean(ans);
    }
    function getAnswerForPyret(mr) {
      var a = getModuleResultAnswer(mr);
      if(isPrimitive(mr.val.runtime, a)) { return runtime.ffi.makeSome(a); }
      else {
        return runtime.ffi.makeNone();
      }
    }
    function getRealm(mr) {
      return mr.val.realm;
    }
    function getResultCompileResult(mr) {
      return mr.val.compileResult;
    }
    function getResultProvides(mr) {
      return mr.val.provides;
    }
    function getModuleResultRuntime(mr) {
      return mr.val.runtime;
    }
    function getModuleResultResult(mr) {
      return mr.val.result;
    }
    function getModuleResultNamespace(mr) {
      return mr.val.runtime.getField(mr.val.result.result, "namespace");
    }
    function getModuleResultDefinedValues(mr) {
      var rt = mr.val.runtime;
      if(rt.hasField(mr.val.result.result, "defined-values")) {
        return mr.val.runtime.getField(mr.val.result.result, "defined-values");
      }
      else {
        return {};
      }
    }
    function getModuleResultDefinedTypes(mr) {
      var rt = mr.val.runtime;
      if(rt.hasField(mr.val.result.result, "defined-types")) {
        return mr.val.runtime.getField(mr.val.result.result, "defined-types");
      }
      else {
        return {};
      }
    }
    function getModuleResultValues(mr) {
      checkSuccess(mr, "values");
      return mr.val.runtime.getField(mr.val.runtime.getField(mr.val.result.result, "provide-plus-types"), "values").dict;
    }
    function getModuleResultTypes(mr) {
      checkSuccess(mr, "types");
      return mr.val.runtime.getField(mr.val.runtime.getField(mr.val.result.result, "provide-plus-types"), "types");
    }
    function getModuleResultChecks(mr) {
      checkSuccess(mr, "checks");
      return mr.val.runtime.getField(mr.val.result.result, "checks");
    }
    function renderCheckResults(mr) {
      runtime.pauseStack(function(restarter) {
        var res = getModuleResultResult(mr);
        var execRt = mr.val.runtime;
        var checkerMod = execRt.modules["builtin://checker"];
        var checker = execRt.getField(checkerMod, "provide-plus-types");
        var toCall = execRt.getField(execRt.getField(checker, "values"), "render-check-results-stack");
        var getStack = function(err) {
          // console.error("The error is: ", err);
          var locArray = err.val.pyretStack.map(execRt.makeSrcloc);
          var locList = execRt.ffi.makeList(locArray);
          return locList;
        };
        var getStackP = execRt.makeFunction(getStack, "get-stack");
        var checks = getModuleResultChecks(mr);
        execRt.runThunk(function() { return toCall.app(checks, getStackP); },
          function(renderedCheckResults) {
            var resumeWith = {
              message: "Unknown error!",
              'exit-code': EXIT_ERROR_UNKNOWN
            };

            if(execRt.isSuccessResult(renderedCheckResults)) {
              resumeWith.message = execRt.unwrap(execRt.getField(renderedCheckResults.result, "message"));
              var errs = execRt.getField(renderedCheckResults.result, "errored");
              var failed = execRt.getField(renderedCheckResults.result, "failed");
              if(errs !== 0 || failed !== 0) {
                resumeWith["exit-code"] = EXIT_ERROR_CHECK_FAILURES;
              } else {
                resumeWith["exit-code"] = EXIT_SUCCESS;
              }
            }
            else if(execRt.isFailureResult(renderedCheckResults)) {
              console.error(renderedCheckResults.exn);
              resumeWith.message = "There was an exception while formatting the check results";
              resumeWith["exit-code"] = EXIT_ERROR_RENDERING_ERROR;
            }

            restarter.resume(runtime.makeObject({
              message: runtime.makeString(resumeWith.message),
              'exit-code': runtime.makeNumber(resumeWith["exit-code"])
            }));
          });
      });
    }
    function renderCheckReport(mr) {
      runtime.pauseStack(function(restarter) {
        var res = getModuleResultResult(mr);
        var execRt = mr.val.runtime;
        var checkerMod = execRt.modules["builtin://checker"];
        var checker = execRt.getField(checkerMod, "provide-plus-types");
        var toCall = execRt.getField(execRt.getField(checker, "values"), "render-check-report-stack");
        var getStack = function(err) {
          console.error("The error is: ", err);
          var locArray = err.val.pyretStack.map(runtime.makeSrcloc);
          var locList = execRt.ffi.makeList(locArray);
          return locList;
        };
        var getStackP = execRt.makeFunction(getStack, "get-stack");
        var checks = getModuleResultChecks(mr);
        execRt.runThunk(function() { return toCall.app(checks, getStackP);  },
          function(renderedCheckResults) {
            var stats = renderedCheckResults.stats;
            if(execRt.isSuccessResult(renderedCheckResults)) {
              var result = renderedCheckResults.result;
              var resultJSON = execRt.ffi.toJSON(result);
              var obj = {
                'is-error': false,
                message: "",
                error: null,
                report: {
                  result: resultJSON,
                  stats: stats
                }
              };
              restarter.resume(runtime.makeObject({
                message: runtime.makeString(JSON.stringify(obj)),
                'exit-code': runtime.makeNumber(EXIT_SUCCESS)
              }));
            } else if(execRt.isFailureResult(renderedCheckResults)) {
              console.error(renderedCheckResults.exn);
              restarter.resume(runtime.makeObject({
                message: runtime.makeString("There was an exception while formatting the check results"),
                'exit-code': runtime.makeNumber(EXIT_ERROR_RENDERING_ERROR)
              }));
            }
          });
      });
    }
    function renderErrorMessage(mr) {
      var res = getModuleResultResult(mr);
      var execRt = mr.val.runtime;
      runtime.pauseStack(function(restarter) {
        // TODO(joe): This works because it's a builtin and already loaded on execRt.
        // In what situations may this not work?
        var rendererrorMod = execRt.modules["builtin://render-error-display"];
        var rendererror = execRt.getField(rendererrorMod, "provide-plus-types");
        var gf = execRt.getField;
        execRt.runThunk(function() {
          if(execRt.isPyretVal(res.exn.exn) 
             && execRt.isObject(res.exn.exn) 
             && execRt.hasField(res.exn.exn, "render-reason")) {
            return execRt.safeCall(
              function() { 
                return execRt.getColonField(res.exn.exn, "render-reason").full_meth(res.exn.exn);
              }, function(reason) {
                return execRt.safeCall(
                  function() { 
                    return gf(gf(rendererror, "values"), "display-to-string").app(
                      reason, 
                      execRt.namespace.get("torepr"), 
                      execRt.ffi.makeList(res.exn.pyretStack.map(execRt.makeSrcloc)));
                  }, function(str) {
                    return execRt.string_append(
                      str,
                      execRt.makeString("\nStack trace:\n" +
                                        execRt.printPyretStack(res.exn.pyretStack)));
                  }, "errordisplay->to-string");
              }, "error->display");
          } else {
            return String(res.exn + "\n" + res.exn.stack);
          }
        }, function(v) {
          if(execRt.isSuccessResult(v)) {
            restarter.resume(runtime.makeObject({
              message: v.result,
              'exit-code': runtime.makeNumber(EXIT_ERROR)
            }));
          } else {
            console.error(v.exn);
            restarter.resume(runtime.makeObject({
              message: runtime.makeString("Load error: there was an exception while rendering the exception."),
              'exit-code': runtime.makeNumber(EXIT_ERROR_RENDERING_ERROR)
            }));
          }
        })
      });
    }
    function renderErrorReport(mr) {
      var res = getModuleResultResult(mr);
      var execRt = mr.val.runtime;
      runtime.pauseStack(function(restarter) {
        // TODO(joe): This works because it's a builtin and already loaded on execRt.
        // In what situations may this not work?
        var rendererrorMod = execRt.modules["builtin://render-error-display"];
        var rendererror = execRt.getField(rendererrorMod, "provide-plus-types");
        var gf = execRt.getField;
        execRt.runThunk(function() {
          if(execRt.isPyretVal(res.exn.exn)
             && execRt.isObject(res.exn.exn)
             && execRt.hasField(res.exn.exn, "render-reason")) {
            return execRt.safeCall(
              function() {
                return execRt.getColonField(res.exn.exn, "render-reason").full_meth(res.exn.exn);
              }, function(reason) {
                return execRt.safeCall(
                  function() {
                    return gf(gf(rendererror, "values"), "display-to-string").app(
                      reason,
                      execRt.namespace.get("torepr"),
                      execRt.ffi.makeList(res.exn.pyretStack.map(execRt.makeSrcloc)));
                  }, function(str) {
                    return execRt.string_append(
                      str,
                      execRt.makeString("\nStack trace:\n" +
                                        execRt.printPyretStack(res.exn.pyretStack)));
                  }, "errordisplay->to-string");
              }, "error->display");
          } else {
            return String(res.exn + "\n" + res.exn.stack);
          }
        }, function(v) {
          var stats = v.stats;
          if(execRt.isSuccessResult(v)) {
              var error = execRt.unwrap(v.result);
              var obj = {
                'is-error': true,
                message: "The run ended in error",
                error: error,
                report: {
                  result: null,
                  stats: stats
                }
              };
              restarter.resume(runtime.makeObject({
                message: runtime.makeString(JSON.stringify(obj)),
                'exit-code': runtime.makeNumber(0)
              }));
          } else {
            console.error(v.exn);
            restarter.resume(runtime.makeObject({
              message: runtime.makeString("Load error: there was an exception while rendering the exception."),
              'exit-code': runtime.makeNumber(EXIT_ERROR_RENDERING_ERROR)
            }));
          }
        })
      });
    }
    function getModuleResultAnswer(mr) {
      checkSuccess(mr, "answer");
      return mr.val.runtime.getField(mr.val.result.result, "answer");
    }
    /* ProgramString is a staticModules/depMap/toLoad tuple as a string */
    // TODO(joe): this should take natives as an argument, as well, and requirejs them
    function runProgram(otherRuntimeObj, realmObj, programString, options) {
      var checkAll = runtime.getField(options, "check-all");
      var otherRuntime = runtime.getField(otherRuntimeObj, "runtime").val;
      var realm = Object.create(runtime.getField(realmObj, "realm").val);
      var program = loader.safeEval("return " + programString, {});
      var staticModules = program.staticModules;
      var depMap = program.depMap;
      var toLoad = program.toLoad;

      var main = toLoad[toLoad.length - 1];
      runtime.setParam("currentMainURL", main);

      if(realm["builtin://checker"]) {
        var checker = otherRuntime.getField(otherRuntime.getField(realm["builtin://checker"], "provide-plus-types"), "values");
        // NOTE(joe): This is the place to add checkAll
        var currentChecker = otherRuntime.getField(checker, "make-check-context").app(otherRuntime.makeString(main), checkAll);
        otherRuntime.setParam("current-checker", currentChecker);
      }

      var postLoadHooks = {
        "builtin://srcloc": function(srcloc) {
          otherRuntime.srcloc = otherRuntime.getField(otherRuntime.getField(srcloc, "provide-plus-types"), "values");
        },
        "builtin://ffi": function(ffi) {
          ffi = ffi.jsmod;
          otherRuntime.ffi = ffi;
          otherRuntime["throwMessageException"] = ffi.throwMessageException;
          otherRuntime["throwNoBranchesMatched"] = ffi.throwNoBranchesMatched;
          otherRuntime["throwNoCasesMatched"] = ffi.throwNoCasesMatched;
          otherRuntime["throwNonBooleanCondition"] = ffi.throwNonBooleanCondition;
          otherRuntime["throwNonBooleanOp"] = ffi.throwNonBooleanOp;
          otherRuntime["throwUnfinishedTemplate"] = ffi.throwUnfinishedTemplate;

          var checkList = otherRuntime.makeCheckType(ffi.isList, "List");
          otherRuntime["checkList"] = checkList;

          otherRuntime["checkEQ"] = otherRuntime.makeCheckType(ffi.isEqualityResult, "EqualityResult");
        },
        "builtin://checker": function(checker) {
          var checker = otherRuntime.getField(otherRuntime.getField(checker, "provide-plus-types"), "values");
          // NOTE(joe): This is the place to add checkAll
          var currentChecker = otherRuntime.getField(checker, "make-check-context").app(otherRuntime.makeString(main), checkAll);
          otherRuntime.setParam("current-checker", currentChecker);
        }
      };


      runtime.pauseStack(function(restarter) {
        var mainReached = false;
        var mainResult = "Main result unset: should not happen";
        postLoadHooks[main] = function(answer) {
          mainReached = true;
          mainResult = answer;
        }
        return otherRuntime.runThunk(function() {
          otherRuntime.modules = realm;
          return otherRuntime.runStandalone(staticModules, realm, depMap, toLoad, postLoadHooks);
        }, function(result) {
          if(!mainReached) {
            // NOTE(joe): we should only reach here if there was an error earlier
            // on in the chain of loading that stopped main from running
            restarter.resume(makeModuleResult(otherRuntime, result, makeRealm(realm), runtime.nothing));
          }
          else {
            var finalResult = otherRuntime.makeSuccessResult(mainResult);
            finalResult.stats = result.stats;
            restarter.resume(makeModuleResult(otherRuntime, finalResult, makeRealm(realm), runtime.nothing));
          }
        });
      });

    }
    var vals = {
      "run-program": runtime.makeFunction(runProgram, "run-program"),
      "is-success-result": runtime.makeFunction(isSuccessResult, "is-success-result"),
      "is-failure-result": runtime.makeFunction(isFailureResult, "is-failure-result"),
      "get-result-answer": runtime.makeFunction(getAnswerForPyret, "get-result-answer"),
      "get-result-realm": runtime.makeFunction(getRealm, "get-result-realm"),
      "get-result-compile-result": runtime.makeFunction(getResultCompileResult, "get-result-compile-result"),
      "render-check-results": runtime.makeFunction(renderCheckResults, "render-check-results"),
      "render-check-report": runtime.makeFunction(renderCheckReport, "render-check-report"),
      "render-error-message": runtime.makeFunction(renderErrorMessage, "render-error-message"),
      "render-error-report": runtime.makeFunction(renderErrorReport, "render-error-report"),
      "empty-realm": runtime.makeFunction(emptyRealm, "empty-realm")
    };
    var types = {
      Module: annModule,
      ModuleResult: annModuleResult,
      Realm: annRealm
    };
    return runtime.makeObject({
      'defined-values': vals,
      'defined-types': types,
      "provide-plus-types": runtime.makeObject({
        values: runtime.makeObject(vals),
        types: types,
        internal: {
          makeRealm: makeRealm,
          getModuleResultAnswer: getModuleResultAnswer,
          getModuleResultChecks: getModuleResultChecks,
          getModuleResultTypes: getModuleResultTypes,
          getModuleResultValues: getModuleResultValues,
          getModuleResultRuntime: getModuleResultRuntime,
          getModuleResultResult: getModuleResultResult,
          getModuleResultNamespace: getModuleResultNamespace,
          getModuleResultDefinedTypes: getModuleResultDefinedTypes,
          getModuleResultDefinedValues: getModuleResultDefinedValues
        }
      })
    });
  }
})
