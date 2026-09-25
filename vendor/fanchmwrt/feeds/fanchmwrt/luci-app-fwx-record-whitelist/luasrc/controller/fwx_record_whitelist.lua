module("luci.controller.fwx_record_whitelist", package.seeall)

local util = require "luci.util"
local jsonc = require "luci.jsonc"

local function normalize_mac(mac)
    mac = string.upper((mac or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    return mac
end

local function is_valid_mac(mac)
    return mac and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

function index()
    entry({"admin", "fwx_internet_record", "record_whitelist"}, template("fwx_record_whitelist/index"), _("Record Whitelist"), 81).dependent = true

    entry({"admin", "internet_record_whitelist_api", "get_record_whitelist"}, call("get_record_whitelist")).leaf = true
    entry({"admin", "internet_record_whitelist_api", "get_record_whitelist_all"}, call("get_record_whitelist_all")).leaf = true
    entry({"admin", "internet_record_whitelist_api", "add_record_whitelist"}, call("add_record_whitelist")).leaf = true
    entry({"admin", "internet_record_whitelist_api", "del_record_whitelist"}, call("del_record_whitelist")).leaf = true
    entry({"admin", "internet_record_whitelist_api", "get_all_users"}, call("get_all_users")).leaf = true
end

function get_record_whitelist()
    local page = tonumber(luci.http.formvalue("page") or "1") or 1
    local page_size = tonumber(luci.http.formvalue("page_size") or "15") or 15

    if page < 1 then page = 1 end
    if page_size < 1 then page_size = 15 end
    if page_size > 200 then page_size = 200 end

    local req_obj = {
        api = "get_record_whitelist",
        data = {
            page = page,
            page_size = page_size
        }
    }

    local resp_obj = util.ubus("fwx", "common", req_obj)
    luci.http.prepare_content("application/json")
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

function get_record_whitelist_all()
    local all_list = {}
    local total_page = 1
    local page = 1
    local page_size = 200

    while page <= total_page do
        local req_obj = {
            api = "get_record_whitelist",
            data = {
                page = page,
                page_size = page_size
            }
        }

        local resp_obj = util.ubus("fwx", "common", req_obj)
        if not (resp_obj and resp_obj.code == 2000 and resp_obj.data and type(resp_obj.data.list) == "table") then
            break
        end

        local i
        for i = 1, #resp_obj.data.list do
            all_list[#all_list + 1] = resp_obj.data.list[i]
        end

        total_page = tonumber(resp_obj.data.total_page or 1) or 1
        if total_page < 1 then
            total_page = 1
        end
        page = page + 1
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        data = {
            list = all_list
        }
    })
end

function add_record_whitelist()
    local data_str = luci.http.formvalue("data")
    local mac = normalize_mac(luci.http.formvalue("mac"))
    local req_obj
    local mac_list = {}

    if data_str and data_str ~= "" then
        local parsed = jsonc.parse(data_str)
        if parsed and type(parsed.mac_list) == "table" then
            local i
            for i = 1, #parsed.mac_list do
                local one_mac = normalize_mac(parsed.mac_list[i])
                if is_valid_mac(one_mac) then
                    mac_list[#mac_list + 1] = one_mac
                end
            end
        end
    end

    if #mac_list == 0 and is_valid_mac(mac) then
        mac_list = {mac}
    end

    if #mac_list == 0 then
        luci.http.prepare_content("application/json")
        luci.http.write_json({code = 1, msg = "invalid mac"})
        return
    end

    req_obj = {
        api = "add_record_whitelist",
        data = {
            mac_list = mac_list
        }
    }

    local resp_obj = util.ubus("fwx", "common", req_obj)
    luci.http.prepare_content("application/json")
    if resp_obj and resp_obj.code == 2000 then
        luci.http.write_json({code = 2000})
    else
        luci.http.write_json({code = 1})
    end
end

function get_all_users()
    local all_list = {}
    local total_page = 1
    local page = 1
    local page_size = 200

    while page <= total_page do
        local req_obj = {
            api = "get_all_users",
            data = {
                flag = 2,
                page = page,
                page_size = page_size
            }
        }

        local resp_obj = util.ubus("fwx", "common", req_obj)
        if not (resp_obj and resp_obj.code == 2000 and resp_obj.data and type(resp_obj.data.list) == "table") then
            break
        end

        local i
        for i = 1, #resp_obj.data.list do
            all_list[#all_list + 1] = resp_obj.data.list[i]
        end

        total_page = tonumber(resp_obj.data.total_page or 1) or 1
        if total_page < 1 then
            total_page = 1
        end
        page = page + 1
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        data = {
            list = all_list
        }
    })
end

function del_record_whitelist()
    local mac = normalize_mac(luci.http.formvalue("mac"))

    if not is_valid_mac(mac) then
        luci.http.prepare_content("application/json")
        luci.http.write_json({code = 1, msg = "invalid mac"})
        return
    end

    local req_obj = {
        api = "del_record_whitelist",
        data = {
            mac = mac
        }
    }

    local resp_obj = util.ubus("fwx", "common", req_obj)
    luci.http.prepare_content("application/json")
    if resp_obj and resp_obj.code == 2000 then
        luci.http.write_json({code = 2000})
    else
        luci.http.write_json({code = 1})
    end
end
