var r = require("requirejs")

define(["./matchers", "../js-numbers/src/js-numbers"], function (matchers, jsnums) {

  _ = require('jasmine-node');
  var path = require('path');
  var addPyretMatchers = matchers.addPyretMatchers;

  function performTest(useCompiled){

    if(useCompiled) {
        R = r('../anf-comp');
    }
    else {
        R = r('../runtime-anf');
    }

    var output;
    var rt;

    /**@ param {string} str, output*/
    function stdout(str) {
        output += str;
    }

    //Booleans for testing
    var pTrue,
        pFalse,
        pTrueExt,
        pFalseExt,
        pNum,
    //Thunks for testing
        thunkTrue,
        thunkFalse,
        thunkNum;


    beforeEach(function(){
        addPyretMatchers(this);
        output = "";
        rt = R.makeRuntime({'stdout' : stdout});

       //Make Test Values

        pTrue = rt.makeBoolean(true);
        pFalse = rt.makeBoolean(false);

    });

    function checkForPyretError(thunk) {
      try{ 
          thunk();
      }
      catch(e) {
          expect(rt.isPyretException(e)).toBe(true);
          return;
      }

      throw new Error("Expression did not result in error");
    }

    describe("Branding", function() {
      it("should not affect original object", function() {
          var o = rt.makeObject({x: rt.makeNumber(5)});
          var b = rt.namespace.get("brander").app();
          var o2 = rt.getField(b, "brand").app(o);
          expect(rt.getField(b, "test").app(o2)).toBe(pTrue);
          console.log(rt.getField(b, "test").app(o));
          expect(rt.getField(b, "test").app(o)).toBe(pFalse);

      });

      it("should allow multiple brands", function() {
          var gf = rt.getField;
          var o = rt.makeObject({x: rt.makeNumber(5)});
          var b = rt.namespace.get("brander").app();
          var b2 = rt.namespace.get("brander").app();
          var o2 = rt.getField(b, "brand").app(o);
          var o3 = rt.getField(b2, "brand").app(o2);
          expect(gf(b, "test").app(o)).toBe(pFalse);
          expect(gf(b, "test").app(o2)).toBe(pTrue);
          expect(gf(b, "test").app(o3)).toBe(pTrue);
          expect(gf(b2, "test").app(o)).toBe(pFalse);
          expect(gf(b2, "test").app(o2)).toBe(pFalse);
          expect(gf(b2, "test").app(o3)).toBe(pTrue);
      });

    });
  }

  return { performTest : performTest };
});
