// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright(c) 2026 destan19(TT) <www.fanchmwrt.com>
*/
#ifndef __FWX_WIRELESS_H__
#define __FWX_WIRELESS_H__

#include <json-c/json.h>

struct json_object *fwx_api_get_wireless_interface_info(struct json_object *req_obj);
struct json_object *fwx_api_set_wireless_interface_info(struct json_object *req_obj);
struct json_object *fwx_api_get_wireless_radio_info(struct json_object *req_obj);
struct json_object *fwx_api_set_wireless_radio_info(struct json_object *req_obj);

#endif
