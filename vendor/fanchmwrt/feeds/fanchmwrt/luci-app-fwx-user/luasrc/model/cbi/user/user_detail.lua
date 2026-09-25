local ds = require "luci.dispatcher"
local m, s

m = Map("appfilter", translate(""), translate(""))

m:section(SimpleSection).template = "user/user_detail"

return m

