#ifndef __FWX_USER_SUMMARY_H__
#define __FWX_USER_SUMMARY_H__

#include <json-c/json.h>
#include <time.h>
#include "fwx_user.h"

void update_client_daily_summary(client_node_t *client, time_t now,
                                 unsigned long long up_bytes, unsigned long long down_bytes,
                                 unsigned int interval, struct json_object *visits);
void save_all_client_daily_summaries(void);
void release_client_daily_summary(client_node_t *client);
struct json_object *fwx_api_get_user_daily_summary(struct json_object *request);

#endif
