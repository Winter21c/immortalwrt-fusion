module("luci.controller.mac_blacklist", package.seeall)

function index()
	entry({"admin", "fwx_parental_control"}, firstchild(), _("Parental Control"), 20).dependent = true
	entry({"admin", "fwx_parental_control", "mac_blacklist"}, cbi("mac_blacklist/list", {hideapplybtn=true, hidesavebtn=true, hideresetbtn=true}), _("Internet Blacklist"), 35).leaf = true
end
