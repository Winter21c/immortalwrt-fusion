module("luci.controller.fwx_user_record", package.seeall)

function index()
    local online_offline_node

    entry({"admin", "fwx_monitor"}, firstchild(), _("System Monitor"), 12).dependent = true
    entry({"admin", "fwx_monitor", "user_record"}, alias("admin", "fwx_monitor", "user_record", "online_offline"), _("User Records"), 52).dependent = true
    online_offline_node = entry({"admin", "fwx_monitor", "user_record", "online_offline"}, template("fwx_user_record/user_record"), _("Online/Offline Records"), 10)
    online_offline_node.leaf = true
    online_offline_node.dependent = true
    entry({"admin", "fwx_monitor", "user_record", "user_record"}, alias("admin", "fwx_monitor", "user_record", "online_offline"), nil, 11).leaf = true
    entry({"admin", "user_record_api", "get_user_records"}, call("get_user_records")).leaf = true
end


function get_user_records()
    local util = require "luci.util"
    local mac = luci.http.formvalue("mac")
    local start_time = tonumber(luci.http.formvalue("start_time") or "0") or 0
    local end_time = tonumber(luci.http.formvalue("end_time") or "0") or 0
    local page = tonumber(luci.http.formvalue("page") or "1") or 1
    local page_size = tonumber(luci.http.formvalue("page_size") or "15") or 15

    luci.http.prepare_content("application/json")

    local req_obj = {
        api = "get_user_records",
        data = {
            mac = mac,
            start_time = start_time,
            end_time = end_time,
            page = page,
            page_size = page_size
        }
    }

    local resp_obj = util.ubus("fwx", "common", req_obj)
    if resp_obj and resp_obj.code == 2000 and resp_obj.data then
        luci.http.write_json(resp_obj.data)
    else
        luci.http.write_json({
            total_num = 0,
            total_page = 1,
            page = page,
            page_size = page_size,
            list = {}
        })
    end
end
