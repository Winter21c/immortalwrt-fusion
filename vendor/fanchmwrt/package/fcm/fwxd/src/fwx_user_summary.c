#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include "fwx.h"
#include "fwx_config.h"
#include "fwx_user_summary.h"

#define SUMMARY_SCHEMA_VERSION 1
#define SUMMARY_TOP_APP_COUNT 3
#define SUMMARY_RETAIN_DAYS 30

static const char *summary_categories[] = { "chat", "game", "video", "shopping", "music" };

static int summary_mac_valid(const char *mac)
{
    size_t i;
    if (!mac || strlen(mac) != 17) return 0;
    for (i = 0; i < 17; i++) {
        if (i % 3 == 2 ? mac[i] != ':' : !isxdigit((unsigned char)mac[i])) return 0;
    }
    return 1;
}

static int summary_date(time_t now, char *date, size_t size)
{
    struct tm tm;
    return localtime_r(&now, &tm) && strftime(date, size, "%Y-%m-%d", &tm) ? 0 : -1;
}

static int summary_mkdir(const char *directory)
{
    char path[512];
    char *p;
    if (snprintf(path, sizeof(path), "%s", directory) >= (int)sizeof(path)) return -1;
    for (p = path + 1; ; p++) {
        char saved = *p;
        if (saved == '/' || saved == '\0') {
            *p = '\0';
            if (mkdir(path, 0700) != 0 && errno != EEXIST) return -1;
            *p = saved;
        }
        if (!saved) break;
    }
    return 0;
}

static int summary_directory(const char *mac, char *path, size_t size)
{
    char mac_dir[18];
    int i;
    if (!summary_mac_valid(mac)) return -1;
    for (i = 0; i < 18; i++) mac_dir[i] = mac[i] == ':' ? '_' : tolower((unsigned char)mac[i]);
    return snprintf(path, size, "%s/client_backup/%s/summary", get_client_data_root_dir(), mac_dir) >= (int)size ? -1 : 0;
}

static uint64_t summary_number(struct json_object *object, const char *key)
{
    int64_t number = json_object_get_int64(json_object_object_get(object, key));
    return number > 0 ? (uint64_t)number : 0;
}

static void summary_add(struct json_object *object, const char *key, uint64_t amount)
{
    uint64_t previous = summary_number(object, key);
    if (amount > INT64_MAX) return;
    json_object_object_add(object, key, json_object_new_int64(amount > INT64_MAX - previous ? INT64_MAX : previous + amount));
}

static struct json_object *summary_public(struct json_object *state)
{
    struct json_object *result, *apps, *top;
    int ids[SUMMARY_TOP_APP_COUNT] = {0};
    uint64_t seconds[SUMMARY_TOP_APP_COUNT] = {0};
    int i, j;
    result = json_tokener_parse(json_object_to_json_string_ext(state, JSON_C_TO_STRING_PLAIN));
    if (!result) return NULL;
    apps = json_object_object_get(state, "app_seconds");
    json_object_object_foreach(apps, key, value) {
        int id = atoi(key);
        uint64_t duration = summary_number(apps, key);
        (void)value;
        if (id <= 0 || !duration) continue;
        for (i = 0; i < SUMMARY_TOP_APP_COUNT; i++) {
            if (duration > seconds[i] || (duration == seconds[i] && id < ids[i])) {
                for (j = SUMMARY_TOP_APP_COUNT - 1; j > i; j--) {
                    ids[j] = ids[j - 1];
                    seconds[j] = seconds[j - 1];
                }
                ids[i] = id;
                seconds[i] = duration;
                break;
            }
        }
    }
    top = json_object_new_array();
    for (i = 0; i < SUMMARY_TOP_APP_COUNT && ids[i]; i++) {
        struct json_object *app = json_object_new_object();
        const char *name = get_app_name_by_id(ids[i]);
        json_object_object_add(app, "appid", json_object_new_int(ids[i]));
        json_object_object_add(app, "name", json_object_new_string(name ? name : ""));
        json_object_object_add(app, "seconds", json_object_new_int64(seconds[i]));
        json_object_array_add(top, app);
    }
    json_object_object_del(result, "app_seconds");
    json_object_object_add(result, "top_apps", top);
    json_object_object_add(result, "total_bytes", json_object_new_int64(summary_number(state, "up_bytes")));
    summary_add(result, "total_bytes", summary_number(state, "down_bytes"));
    return result;
}

static void summary_cleanup(time_t now)
{
    static char last_date[16];
    char date[16], cutoff[16], root[512];
    struct tm day;
    DIR *users;
    struct dirent *user;
    int failed = 0;
    if (now < 1577836800 || summary_date(now, date, sizeof(date)) || !strcmp(date, last_date)) return;
    if (!localtime_r(&now, &day)) return;
    day.tm_mday -= SUMMARY_RETAIN_DAYS - 1;
    day.tm_isdst = -1;
    if (summary_date(mktime(&day), cutoff, sizeof(cutoff))) return;
    if (snprintf(root, sizeof(root), "%s/client_backup", get_client_data_root_dir()) >= (int)sizeof(root)) return;
    users = opendir(root);
    if (!users) return;
    while ((user = readdir(users)) != NULL) {
        char mac[18], directory[512];
        DIR *files;
        struct dirent *file;
        int i;
        if (strlen(user->d_name) != 17) continue;
        for (i = 0; i < 18; i++) mac[i] = user->d_name[i] == '_' ? ':' : user->d_name[i];
        if (summary_directory(mac, directory, sizeof(directory))) continue;
        files = opendir(directory);
        if (!files) {
            if (errno != ENOENT) failed = 1;
            continue;
        }
        while ((file = readdir(files)) != NULL) {
            char path[560], file_date[16];
            struct stat st;
            if (strlen(file->d_name) != 15 || strcmp(file->d_name + 10, ".json")) continue;
            memcpy(file_date, file->d_name, 10);
            file_date[10] = '\0';
            if (strspn(file_date, "0123456789-") != 10 || file_date[4] != '-' || file_date[7] != '-') continue;
            if (strcmp(file_date, cutoff) >= 0) continue;
            snprintf(path, sizeof(path), "%s/%s", directory, file->d_name);
            if (lstat(path, &st) || !S_ISREG(st.st_mode)) continue;
            if (unlink(path)) {
                failed = 1;
                LOG_ERROR("Failed to remove expired summary %s\n", path);
            }
        }
        closedir(files);
    }
    closedir(users);
    if (!failed) snprintf(last_date, sizeof(last_date), "%s", date);
}

static int summary_save(client_node_t *client)
{
    char directory[512], path[560], temporary[576], today[16];
    struct json_object *summary;
    const char *date, *text;
    FILE *file;
    int fd, rc = -1;
    if (!client->daily_summary) return 0;
    date = json_object_get_string(json_object_object_get(client->daily_summary, "date"));
    if (!date || strlen(date) != 10 || strspn(date, "0123456789-") != 10 || date[4] != '-' || date[7] != '-') return -1;
    if (summary_date(time(NULL), today, sizeof(today))) return -1;
    if (strcmp(date, today) >= 0) return 0;
    if (summary_directory(client->mac, directory, sizeof(directory)) || summary_mkdir(directory)) return -1;
    snprintf(path, sizeof(path), "%s/%s.json", directory, date);
    if (!access(path, F_OK)) return 0;
    summary = summary_public(client->daily_summary);
    if (!summary) return -1;
    snprintf(temporary, sizeof(temporary), "%s.tmp.XXXXXX", path);
    fd = mkstemp(temporary);
    if (fd < 0) goto done;
    file = fdopen(fd, "w");
    if (!file) {
        close(fd);
        unlink(temporary);
        goto done;
    }
    text = json_object_to_json_string_ext(summary, JSON_C_TO_STRING_PLAIN);
    if (fputs(text, file) >= 0 && !fflush(file) && !fsync(fd)) rc = 0;
    if (fclose(file)) rc = -1;
    if (!rc && rename(temporary, path)) rc = -1;
    if (rc) unlink(temporary);
done:
    json_object_put(summary);
    if (rc) LOG_ERROR("Failed to archive daily summary for %s\n", client->mac);
    return rc;
}

static void summary_restore_today(client_node_t *client, struct json_object *state, const char *date)
{
    char saved_date[16], key[16];
    int i;
    struct json_object *apps = json_object_object_get(state, "app_seconds");
    struct json_object *categories = json_object_object_get(state, "category_seconds");
    if (!summary_date(client->daily_stats.date, saved_date, sizeof(saved_date)) && !strcmp(date, saved_date)) {
        for (i = 0; i < HOURS_PER_DAY; i++) {
            summary_add(state, "up_bytes", client->daily_stats.hourly_traffic[i].up_bytes);
            summary_add(state, "down_bytes", client->daily_stats.hourly_traffic[i].down_bytes);
            summary_add(state, "online_seconds", client->daily_stats.hourly_online_time[i]);
            summary_add(state, "active_seconds", client->daily_stats.hourly_active_time[i]);
        }
    }
    if (summary_date(client->daily_top_apps_stats.date, saved_date, sizeof(saved_date)) || strcmp(date, saved_date)) return;
    for (i = 0; i < client->daily_top_apps_stats.count && i < MAX_TOP_APPS_PER_DAY; i++) {
        int id = client->daily_top_apps_stats.apps[i].appid;
        int category = id / 1000;
        if (id <= 0) continue;
        snprintf(key, sizeof(key), "%d", id);
        summary_add(apps, key, client->daily_top_apps_stats.apps[i].total_time);
        if (category >= 1 && category <= 5)
            summary_add(categories, summary_categories[category - 1], client->daily_top_apps_stats.apps[i].total_time);
    }
}

static struct json_object *summary_prepare(client_node_t *client, time_t now)
{
    char date[16];
    const char *previous;
    struct json_object *state, *categories;
    size_t i;
    if (now < 1577836800 || summary_date(now, date, sizeof(date))) return NULL;
    if (client->daily_summary) {
        previous = json_object_get_string(json_object_object_get(client->daily_summary, "date"));
        if (!strcmp(previous, date)) return client->daily_summary;
        if (strcmp(previous, date) > 0 || summary_save(client)) return NULL;
        json_object_put(client->daily_summary);
        client->daily_summary = NULL;
    }
    state = json_object_new_object();
    categories = json_object_new_object();
    if (!state || !categories) {
        if (state) json_object_put(state);
        if (categories) json_object_put(categories);
        return NULL;
    }
    json_object_object_add(state, "schema_version", json_object_new_int(SUMMARY_SCHEMA_VERSION));
    json_object_object_add(state, "date", json_object_new_string(date));
    json_object_object_add(state, "mac", json_object_new_string(client->mac));
    json_object_object_add(state, "hostname", json_object_new_string(client->hostname));
    json_object_object_add(state, "nickname", json_object_new_string(client->nickname));
    json_object_object_add(state, "started_at", json_object_new_int64(now));
    json_object_object_add(state, "updated_at", json_object_new_int64(now));
    json_object_object_add(state, "up_bytes", json_object_new_int64(0));
    json_object_object_add(state, "down_bytes", json_object_new_int64(0));
    json_object_object_add(state, "online_seconds", json_object_new_int64(0));
    json_object_object_add(state, "active_seconds", json_object_new_int64(0));
    json_object_object_add(state, "app_seconds", json_object_new_object());
    for (i = 0; i < sizeof(summary_categories) / sizeof(summary_categories[0]); i++) {
        json_object_object_add(categories, summary_categories[i], json_object_new_int64(0));
    }
    json_object_object_add(state, "category_seconds", categories);
    summary_restore_today(client, state, date);
    client->daily_summary = state;
    return state;
}

void update_client_daily_summary(client_node_t *client, time_t now,
                                 unsigned long long up_bytes, unsigned long long down_bytes,
                                 unsigned int interval, struct json_object *visits)
{
    struct json_object *state, *apps, *categories, *seen;
    size_t i;
    if (!client || !interval || !summary_mac_valid(client->mac)) return;
    state = summary_prepare(client, now);
    if (!state) return;
    summary_add(state, "up_bytes", up_bytes);
    summary_add(state, "down_bytes", down_bytes);
    summary_add(state, "online_seconds", client->online == 1 ? interval : 0);
    summary_add(state, "active_seconds", client->active == 1 ? interval : 0);
    json_object_object_add(state, "updated_at", json_object_new_int64(now));
    if (!json_object_is_type(visits, json_type_array)) return;
    apps = json_object_object_get(state, "app_seconds");
    categories = json_object_object_get(state, "category_seconds");
    seen = json_object_new_object();
    if (!seen) return;
    for (i = 0; i < json_object_array_length(visits); i++) {
        struct json_object *visit = json_object_array_get_idx(visits, i);
        int appid = json_object_get_int(json_object_object_get(visit, "appid"));
        int category = appid / 1000;
        char key[16];
        if (appid % 1000 <= 0 || category < 1 || category > MAX_APP_TYPE) continue;
        snprintf(key, sizeof(key), "%d", appid);
        if (json_object_object_get(seen, key)) continue;
        json_object_object_add(seen, key, json_object_new_boolean(1));
        summary_add(apps, key, interval);
        if (category <= 5) summary_add(categories, summary_categories[category - 1], interval);
    }
    json_object_put(seen);
}

void save_all_client_daily_summaries(void)
{
    extern struct list_head client_list;
    client_node_t *client;
    time_t now = time(NULL);
    list_for_each_entry(client, &client_list, client) {
        summary_prepare(client, now);
    }
    summary_cleanup(now);
}

void release_client_daily_summary(client_node_t *client)
{
    if (!client) return;
    summary_save(client);
    if (client->daily_summary) json_object_put(client->daily_summary);
    client->daily_summary = NULL;
}

static int summary_query_end(struct json_object *request, struct tm *end)
{
    struct json_object *value = json_object_object_get(request, "end_date");
    time_t now = time(NULL), timestamp;
    char normalized[16], extra;
    int year, month, day;
    if (!localtime_r(&now, end)) return -1;
    if (value) {
        const char *date = json_object_get_string(value);
        if (!json_object_is_type(value, json_type_string) || strlen(date) != 10 ||
            sscanf(date, "%4d-%2d-%2d%c", &year, &month, &day, &extra) != 3 || year < 2020 || year > 2099) return -1;
        end->tm_year = year - 1900;
        end->tm_mon = month - 1;
        end->tm_mday = day;
    }
    end->tm_hour = end->tm_min = end->tm_sec = 0;
    end->tm_isdst = -1;
    timestamp = mktime(end);
    if (timestamp == (time_t)-1 || timestamp > now || summary_date(timestamp, normalized, sizeof(normalized))) return -1;
    if (value && strcmp(normalized, json_object_get_string(value))) return -1;
    return 0;
}

struct json_object *fwx_api_get_user_daily_summary(struct json_object *request)
{
    extern struct list_head client_list;
    struct json_object *data = NULL, *list = NULL, *value;
    client_node_t *client, *matched = NULL;
    struct tm end;
    const char *mac;
    int days = 30, i;
    char start_date[16], end_date[16];
    value = json_object_object_get(request, "mac");
    if (!json_object_is_type(value, json_type_string)) goto fail;
    mac = json_object_get_string(value);
    if (!summary_mac_valid(mac) || summary_query_end(request, &end)) goto fail;
    value = json_object_object_get(request, "days");
    if (value) {
        if (!json_object_is_type(value, json_type_int)) goto fail;
        days = json_object_get_int(value);
    }
    if (days < 1 || days > 366) goto fail;
    list_for_each_entry(client, &client_list, client) {
        if (!strcasecmp(client->mac, mac)) {
            matched = client;
            mac = client->mac;
            break;
        }
    }
    if (matched) summary_prepare(matched, time(NULL));
    list = json_object_new_array();
    data = json_object_new_object();
    if (!list || !data) goto fail;
    for (i = days - 1; i >= 0; i--) {
        struct tm day = end;
        struct json_object *item = NULL;
        char date[16];
        time_t timestamp;
        day.tm_mday -= i;
        day.tm_isdst = -1;
        timestamp = mktime(&day);
        if (timestamp == (time_t)-1 || summary_date(timestamp, date, sizeof(date))) goto fail;
        if (i == days - 1) snprintf(start_date, sizeof(start_date), "%s", date);
        if (i == 0) snprintf(end_date, sizeof(end_date), "%s", date);
        if (matched && matched->daily_summary && !strcmp(date,
            json_object_get_string(json_object_object_get(matched->daily_summary, "date")))) {
            item = summary_public(matched->daily_summary);
            if (!item) goto fail;
        } else {
            char directory[512], path[560];
            if (summary_directory(mac, directory, sizeof(directory))) goto fail;
            snprintf(path, sizeof(path), "%s/%s.json", directory, date);
            if (!access(path, F_OK)) {
                item = json_object_from_file(path);
                if (!json_object_is_type(item, json_type_object)) {
                    if (item) json_object_put(item);
                    goto fail;
                }
            } else if (errno != ENOENT) goto fail;
        }
        if (item) {
            json_object_object_add(item, "available", json_object_new_boolean(1));
        } else {
            item = json_object_new_object();
            json_object_object_add(item, "date", json_object_new_string(date));
            json_object_object_add(item, "available", json_object_new_boolean(0));
        }
        json_object_array_add(list, item);
    }
    json_object_object_add(data, "mac", json_object_new_string(mac));
    json_object_object_add(data, "days", json_object_new_int(days));
    json_object_object_add(data, "start_date", json_object_new_string(start_date));
    json_object_object_add(data, "end_date", json_object_new_string(end_date));
    json_object_object_add(data, "list", list);
    return fwx_gen_api_response_data(API_CODE_SUCCESS, data);
fail:
    if (list) json_object_put(list);
    if (data) json_object_put(data);
    return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
}
