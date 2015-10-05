provide *
provide-types *

type Pin = String

var A0 :: Pin = "A0"
var A1 :: Pin = "A1"
var A2 :: Pin = "A2"
var A3 :: Pin = "A3"
var A4 :: Pin = "A4"
var A5 :: Pin = "A5"
var A6 :: Pin = "A6"
var A7 :: Pin = "A7"

var D0 :: Pin = "D0"
var D1 :: Pin = "D1"
var D2 :: Pin = "D2"
var D3 :: Pin = "D3"
var D4 :: Pin = "D4"
var D5 :: Pin = "D5"
var D6 :: Pin = "D6"
var D7 :: Pin = "D7"

data AnalogInputTrigger:
  | ait-enters(min :: Number, max :: Number) with:
    _shim-convert(self):
      tostring(self.min) + "-" + tostring(self.max)
    end
  | ait-exits(min :: Number, max :: Number) with:
    _shim-convert(self):
      tostring(self.max) + "-" + tostring(self.min)
    end
  | ait-crosses(mid :: Number) with:
    _shim-convert(self):
      tostring(self.mid) + "-" + tostring(self.mid)
    end
end

data PinConfig:
  | pc-write(pin :: Pin, event :: String) with:
    _shim-convert(self):
      self.pin + ":" + self.event + "\n"
    end
  | pc-digital-read(pin :: Pin, event :: String) with:
    _shim-convert(self):
      self.pin + ":" + self.event + "\n"
    end
  | pc-analog-read(pin :: Pin, event :: String, trigger :: AnalogInputTrigger) with:
    _shim-convert(self):
      self.pin + ":" + self.event + ":" + self.trigger._shim-convert() + "\n"
    end
end

type CoreConfig = List<PinConfig>
