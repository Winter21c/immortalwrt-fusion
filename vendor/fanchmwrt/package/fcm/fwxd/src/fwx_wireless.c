// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright(c) 2026 destan19(TT) <www.fanchmwrt.com>
*/
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <ctype.h>
#include <json-c/json.h>
#include <uci.h>
#include "fwx.h"
#include "fwx_wireless.h"

#define MAX_WIRELESS_SECTION_NUM 64
#define MAX_WIRELESS_NAME_LEN 64

static int get_wireless_option_value(struct uci_context *ctx, const char *section_name, const char *option_name, char *out, size_t out_len)
{
    char uci_key[128] = {0};

    if (!ctx || !section_name || !section_name[0] || !option_name || !out || out_len == 0) {
        if (out && out_len) out[0] = '\0';
        return -1;
    }

    snprintf(uci_key, sizeof(uci_key), "wireless.%s.%s", section_name, option_name);
    if (fwx_uci_get_value(ctx, uci_key, out, (int)out_len) == 0) {
        return 0;
    }

    out[0] = '\0';
    return -1;
}

static int set_wireless_option_value(struct uci_context *ctx, const char *section_name, const char *option_name, const char *value)
{
    char uci_key[128] = {0};

    if (!ctx || !section_name || !option_name || !value) {
        return -1;
    }

    snprintf(uci_key, sizeof(uci_key), "wireless.%s.%s", section_name, option_name);
    return fwx_uci_set_value(ctx, uci_key, (char *)value);
}

static int delete_wireless_option_value(struct uci_context *ctx, const char *section_name, const char *option_name)
{
    char uci_key[128] = {0};
    char value[128] = {0};

    if (!ctx || !section_name || !option_name) {
        return -1;
    }

    snprintf(uci_key, sizeof(uci_key), "wireless.%s.%s", section_name, option_name);
    if (fwx_uci_get_value(ctx, uci_key, value, sizeof(value)) != 0) {
        return 0;
    }
    return fwx_uci_delete(ctx, uci_key);
}

static int valid_iwinfo_device_name(const char *device)
{
    size_t i = 0;

    if (!device || !device[0]) {
        return 0;
    }

    for (i = 0; device[i]; i++) {
        if (!isalnum((unsigned char)device[i]) && device[i] != '_' && device[i] != '-' && device[i] != '.') {
            return 0;
        }
    }

    return 1;
}

static char *get_command_output(const char *cmd)
{
    FILE *fp = NULL;
    char *buf = NULL;
    size_t buf_size = 4096;
    size_t total_read = 0;

    if (!cmd || !cmd[0]) {
        return NULL;
    }

    fp = popen(cmd, "r");
    if (!fp) {
        return NULL;
    }

    buf = (char *)calloc(1, buf_size);
    if (!buf) {
        pclose(fp);
        return NULL;
    }

    while (!feof(fp)) {
        size_t remain = buf_size - total_read - 1;
        size_t n_read = 0;
        if (remain < 512) {
            char *new_buf = NULL;
            buf_size *= 2;
            new_buf = (char *)realloc(buf, buf_size);
            if (!new_buf) {
                free(buf);
                pclose(fp);
                return NULL;
            }
            buf = new_buf;
            remain = buf_size - total_read - 1;
        }

        n_read = fread(buf + total_read, 1, remain, fp);
        total_read += n_read;
        if (ferror(fp)) {
            free(buf);
            pclose(fp);
            return NULL;
        }
    }

    pclose(fp);
    if (!total_read) {
        free(buf);
        return NULL;
    }

    buf[total_read] = '\0';
    return buf;
}

static struct json_object *get_command_json(const char *cmd)
{
    char *output = NULL;
    struct json_object *obj = NULL;

    output = get_command_output(cmd);
    if (!output) {
        return NULL;
    }

    obj = json_tokener_parse(output);
    free(output);
    return obj;
}

static int collect_wireless_sections(struct uci_context *ctx,
                                     char radio_names[][MAX_WIRELESS_NAME_LEN], int *radio_num,
                                     char iface_names[][MAX_WIRELESS_NAME_LEN], int *iface_num)
{
    struct uci_package *pkg = NULL;
    struct uci_element *e = NULL;

    if (!ctx || !radio_names || !radio_num || !iface_names || !iface_num) {
        return -1;
    }

    *radio_num = 0;
    *iface_num = 0;
    if (uci_load(ctx, "wireless", &pkg) != UCI_OK) {
        return -1;
    }

    uci_foreach_element(&pkg->sections, e) {
        struct uci_section *s = uci_to_section(e);

        if (strcmp(s->type, "wifi-device") == 0) {
            if (*radio_num < MAX_WIRELESS_SECTION_NUM) {
                snprintf(radio_names[*radio_num], MAX_WIRELESS_NAME_LEN, "%s", e->name);
                (*radio_num)++;
            }
            continue;
        }

        if (strcmp(s->type, "wifi-iface") == 0) {
            if (*iface_num < MAX_WIRELESS_SECTION_NUM) {
                snprintf(iface_names[*iface_num], MAX_WIRELESS_NAME_LEN, "%s", e->name);
                (*iface_num)++;
            }
        }
    }

    if (pkg) {
        uci_unload(ctx, pkg);
    }
    return 0;
}

static int find_first_iface_by_radio(struct uci_context *ctx, const char *radio_name,
                                     char iface_names[][MAX_WIRELESS_NAME_LEN], int iface_num,
                                     char *out_iface, size_t out_iface_len)
{
    int i = 0;

    if (!ctx || !radio_name || !iface_names || !out_iface || out_iface_len == 0) {
        return -1;
    }

    for (i = 0; i < iface_num; i++) {
        char device[64] = {0};
        if (get_wireless_option_value(ctx, iface_names[i], "device", device, sizeof(device)) == 0 &&
            strcmp(device, radio_name) == 0) {
            snprintf(out_iface, out_iface_len, "%s", iface_names[i]);
            return 0;
        }
    }

    return -1;
}

static int is_iface_exists(char iface_names[][MAX_WIRELESS_NAME_LEN], int iface_num, const char *section_name)
{
    int i = 0;

    if (!iface_names || !section_name) {
        return 0;
    }

    for (i = 0; i < iface_num; i++) {
        if (strcmp(iface_names[i], section_name) == 0) {
            return 1;
        }
    }

    return 0;
}

static int is_radio_exists(char radio_names[][MAX_WIRELESS_NAME_LEN], int radio_num, const char *section_name)
{
    int i = 0;

    if (!radio_names || !section_name) {
        return 0;
    }

    for (i = 0; i < radio_num; i++) {
        if (strcmp(radio_names[i], section_name) == 0) {
            return 1;
        }
    }

    return 0;
}

static const char *format_band_label(const char *band, const char *hwmode, char *buf, size_t buf_len)
{
    if (!buf || buf_len == 0) {
        return "Unknown";
    }

    if (band && band[0] != '\0') {
        if (strcmp(band, "2g") == 0) {
            snprintf(buf, buf_len, "2.4G");
        } else if (strcmp(band, "5g") == 0) {
            snprintf(buf, buf_len, "5G");
        } else if (strcmp(band, "6g") == 0) {
            snprintf(buf, buf_len, "6G");
        } else if (strcmp(band, "60g") == 0) {
            snprintf(buf, buf_len, "60G");
        } else {
            snprintf(buf, buf_len, "%s", band);
        }

        return buf;
    }

    if (hwmode && hwmode[0] != '\0') {
        if (strstr(hwmode, "11ad") || strstr(hwmode, "11ay")) {
            snprintf(buf, buf_len, "60G");
        } else if (strstr(hwmode, "11a")) {
            snprintf(buf, buf_len, "5G");
        } else {
            snprintf(buf, buf_len, "2.4G");
        }

        return buf;
    }

    snprintf(buf, buf_len, "Unknown");
    return buf;
}

static int parse_hidden_value(const char *hidden)
{
    if (!hidden) {
        return 0;
    }

    if (strcmp(hidden, "1") == 0 ||
        strcasecmp(hidden, "true") == 0 ||
        strcasecmp(hidden, "yes") == 0 ||
        strcasecmp(hidden, "on") == 0) {
        return 1;
    }

    return 0;
}

static int json_to_bool(struct json_object *obj, int default_value)
{
    enum json_type type;
    const char *val_str = NULL;

    if (!obj) {
        return default_value;
    }

    type = json_object_get_type(obj);
    if (type == json_type_boolean || type == json_type_int) {
        return json_object_get_int(obj) ? 1 : 0;
    }

    if (type == json_type_string) {
        val_str = json_object_get_string(obj);
        return parse_hidden_value(val_str);
    }

    return default_value;
}

static int is_open_encryption(const char *encryption)
{
    if (!encryption || encryption[0] == '\0') {
        return 1;
    }

    if (strcmp(encryption, "none") == 0) {
        return 1;
    }

    if (strncmp(encryption, "owe", 3) == 0) {
        return 1;
    }

    return 0;
}

static int wireless_security_features(void)
{
    int features = 0;
    if (access("/usr/sbin/hostapd", X_OK) == 0) {
        features = 1;
        if (system("/usr/sbin/hostapd -vsae >/dev/null 2>&1") == 0) {
            features |= 2;
        }
        if (system("/usr/sbin/hostapd -vowe >/dev/null 2>&1") == 0) {
            features |= 4;
        }
    }
    return features;
}

static int wireless_acs_supported(void)
{
    return access("/usr/sbin/hostapd", X_OK) == 0 &&
        system("/usr/sbin/hostapd -vacs >/dev/null 2>&1") == 0;
}

static struct json_object *get_iwinfo_results(const char *method, const char *device)
{
    char cmd[192] = {0};
    struct json_object *root = NULL;
    struct json_object *results = NULL;

    if (!method || !valid_iwinfo_device_name(method) || !valid_iwinfo_device_name(device)) {
        return NULL;
    }

    snprintf(cmd, sizeof(cmd), "ubus call iwinfo %s '{\"device\":\"%s\"}' 2>/dev/null", method, device);
    root = get_command_json(cmd);
    if (!root) {
        return NULL;
    }

    if (json_object_is_type(root, json_type_array)) {
        return root;
    }

    if (json_object_object_get_ex(root, "results", &results) && results &&
        json_object_is_type(results, json_type_array)) {
        json_object_get(results);
        json_object_put(root);
        return results;
    }

    json_object_put(root);
    return NULL;
}

static void add_choice_object(struct json_object *list, const char *value, const char *label, int available, int no_outdoor)
{
    struct json_object *obj = NULL;

    if (!list || !value || !label) {
        return;
    }

    obj = json_object_new_object();
    if (!obj) {
        return;
    }

    json_object_object_add(obj, "value", json_object_new_string(value));
    json_object_object_add(obj, "label", json_object_new_string(label));
    json_object_object_add(obj, "available", json_object_new_boolean(available));
    if (no_outdoor) {
        json_object_object_add(obj, "no_outdoor", json_object_new_boolean(1));
    }
    json_object_array_add(list, obj);
}

static const char *htmode_family_from_value(const char *htmode, const char *hwmode, char *buf, size_t buf_len)
{
    if (!buf || buf_len == 0) {
        return "";
    }

    buf[0] = '\0';
    if (htmode && !strncmp(htmode, "EHT", 3)) snprintf(buf, buf_len, "be");
    else if (htmode && !strncmp(htmode, "HE", 2)) snprintf(buf, buf_len, "ax");
    else if (htmode && !strncmp(htmode, "VHT", 3)) snprintf(buf, buf_len, "ac");
    else if (htmode && !strncmp(htmode, "HT", 2)) snprintf(buf, buf_len, "n");
    else if (hwmode && (!strcmp(hwmode, "11a") || !strcmp(hwmode, "11b") || !strcmp(hwmode, "11g"))) snprintf(buf, buf_len, "legacy");
    else if (hwmode && hwmode[0]) snprintf(buf, buf_len, "%s", hwmode);

    return buf;
}

static struct json_object *get_radio_info_iwinfo(const char *radio_name);

static const char *get_current_radio_hwmode(const char *radio_name, const char *htmode,
                                            const char *uci_hwmode, char *buf, size_t buf_len)
{
    struct json_object *iwinfo = NULL;
    struct json_object *hwmode_obj = NULL;

    if (!buf || buf_len == 0) {
        return "";
    }

    htmode_family_from_value(htmode, uci_hwmode, buf, buf_len);
    if (buf[0]) {
        return buf;
    }

    iwinfo = get_radio_info_iwinfo(radio_name);
    if (iwinfo && json_object_object_get_ex(iwinfo, "hwmode", &hwmode_obj) && hwmode_obj) {
        snprintf(buf, buf_len, "%s", json_object_get_string(hwmode_obj));
    }
    if (iwinfo) {
        json_object_put(iwinfo);
    }

    return buf;
}

static void add_htmode_choice(struct json_object *list, const char *value, const char *label,
                              struct json_object *htmodes)
{
    int available = 0;
    int i = 0;

    if (!list || !value || !label) {
        return;
    }

    if (!value[0]) {
        add_choice_object(list, value, label, 1, 0);
        return;
    }

    if (htmodes && json_object_is_type(htmodes, json_type_array)) {
        for (i = 0; i < json_object_array_length(htmodes); i++) {
            struct json_object *mode_obj = json_object_array_get_idx(htmodes, i);
            const char *mode = mode_obj ? json_object_get_string(mode_obj) : NULL;
            if (mode && strcmp(mode, value) == 0) {
                available = 1;
                break;
            }
        }
    }

    if (available) {
        add_choice_object(list, value, label, 1, 0);
    }
}

static struct json_object *build_iwinfo_country_list(const char *radio_name)
{
    struct json_object *countries = NULL;
    struct json_object *results = NULL;
    int i = 0;

    countries = json_object_new_array();
    if (!countries) {
        return NULL;
    }
    add_choice_object(countries, "", "driver default", 1, 0);

    results = get_iwinfo_results("countrylist", radio_name);
    if (!results) {
        return countries;
    }

    for (i = 0; i < json_object_array_length(results); i++) {
        struct json_object *item = json_object_array_get_idx(results, i);
        struct json_object *iso_obj = NULL;
        struct json_object *country_obj = NULL;
        const char *iso = NULL;
        const char *country = NULL;
        char label[96] = {0};

        if (!item || !json_object_is_type(item, json_type_object)) {
            continue;
        }
        if (!json_object_object_get_ex(item, "iso3166", &iso_obj) || !iso_obj) {
            continue;
        }

        iso = json_object_get_string(iso_obj);
        if (!iso || !iso[0]) {
            continue;
        }
        if (json_object_object_get_ex(item, "country", &country_obj) && country_obj) {
            country = json_object_get_string(country_obj);
        }

        snprintf(label, sizeof(label), "%s%s%s", iso, country && country[0] ? " - " : "", country && country[0] ? country : "");
        add_choice_object(countries, iso, label, 1, 0);
    }

    json_object_put(results);
    return countries;
}

static struct json_object *build_iwinfo_channel_list(const char *radio_name, const char *current_band)
{
    struct json_object *channels = NULL;
    struct json_object *results = NULL;
    int acs = wireless_acs_supported();
    int i = 0;

    channels = json_object_new_array();
    if (!channels) {
        return NULL;
    }
    if (acs) {
        add_choice_object(channels, "auto", "auto", 1, 0);
    }

    results = get_iwinfo_results("freqlist", radio_name);
    if (!results) {
        return channels;
    }

    for (i = 0; i < json_object_array_length(results); i++) {
        struct json_object *item = json_object_array_get_idx(results, i);
        struct json_object *band_obj = NULL, *channel_obj = NULL, *mhz_obj = NULL;
        struct json_object *restricted_obj = NULL, *flags_obj = NULL, *no_outdoor_obj = NULL;
        const char *band_key = NULL;
        char expected_band[8] = {0};
        char value[16] = {0};
        char label[48] = {0};
        int channel = 0, mhz = 0, restricted = 0, no_ir = 0, no_outdoor = 0;
        int j = 0;

        if (!item || !json_object_is_type(item, json_type_object)) {
            continue;
        }
        if (!json_object_object_get_ex(item, "band", &band_obj) || !band_obj ||
            !json_object_object_get_ex(item, "channel", &channel_obj) || !channel_obj) {
            continue;
        }

        snprintf(expected_band, sizeof(expected_band), "%dg", json_object_get_int(band_obj));
        band_key = current_band ? current_band : "";
        if (band_key[0] && strcmp(band_key, expected_band) != 0) {
            continue;
        }

        channel = json_object_get_int(channel_obj);
        json_object_object_get_ex(item, "mhz", &mhz_obj);
        mhz = mhz_obj ? json_object_get_int(mhz_obj) : 0;
        json_object_object_get_ex(item, "restricted", &restricted_obj);
        restricted = restricted_obj ? json_object_get_boolean(restricted_obj) : 0;
        json_object_object_get_ex(item, "flags", &flags_obj);
        if (flags_obj && json_object_is_type(flags_obj, json_type_array)) {
            for (j = 0; j < json_object_array_length(flags_obj); j++) {
                const char *flag = json_object_get_string(json_object_array_get_idx(flags_obj, j));
                if (flag && strcmp(flag, "no_ir") == 0) {
                    no_ir = 1;
                    break;
                }
            }
        }
        json_object_object_get_ex(item, "no_outdoor", &no_outdoor_obj);
        no_outdoor = no_outdoor_obj ? json_object_get_boolean(no_outdoor_obj) : 0;

        snprintf(value, sizeof(value), "%d", channel);
        if (mhz > 0) {
            snprintf(label, sizeof(label), "%d (%d MHz)", channel, mhz);
        } else {
            snprintf(label, sizeof(label), "%d", channel);
        }
        add_choice_object(channels, value, label, !(restricted && no_ir), no_outdoor);
    }

    json_object_put(results);
    return channels;
}

static struct json_object *get_radio_status_iwinfo(const char *radio_name)
{
    struct json_object *status = NULL;
    struct json_object *radio = NULL;
    struct json_object *iwinfo = NULL;

    if (!valid_iwinfo_device_name(radio_name)) {
        return NULL;
    }

    status = get_command_json("ubus call network.wireless status 2>/dev/null");
    if (!status) {
        return NULL;
    }

    if (json_object_object_get_ex(status, radio_name, &radio) && radio &&
        json_object_is_type(radio, json_type_object) &&
        json_object_object_get_ex(radio, "iwinfo", &iwinfo) && iwinfo &&
        json_object_is_type(iwinfo, json_type_object)) {
        json_object_get(iwinfo);
        json_object_put(status);
        return iwinfo;
    }

    json_object_put(status);
    return NULL;
}

static struct json_object *get_radio_info_iwinfo(const char *radio_name)
{
    char cmd[192] = {0};

    if (!valid_iwinfo_device_name(radio_name)) {
        return NULL;
    }

    snprintf(cmd, sizeof(cmd), "ubus call iwinfo info '{\"device\":\"%s\"}' 2>/dev/null", radio_name);
    return get_command_json(cmd);
}

static struct json_object *build_iwinfo_htmode_list(const char *radio_name)
{
    struct json_object *list = NULL;
    struct json_object *iwinfo = NULL;
    struct json_object *htmodes = NULL;

    list = json_object_new_array();
    if (!list) {
        return NULL;
    }

    iwinfo = get_radio_status_iwinfo(radio_name);
    if (iwinfo) {
        json_object_object_get_ex(iwinfo, "htmodes", &htmodes);
    }
    if (!htmodes || !json_object_is_type(htmodes, json_type_array) || json_object_array_length(htmodes) == 0) {
        if (iwinfo) {
            json_object_put(iwinfo);
        }
        iwinfo = get_radio_info_iwinfo(radio_name);
        if (iwinfo) {
            json_object_object_get_ex(iwinfo, "htmodes", &htmodes);
        }
    }

    add_htmode_choice(list, "", "auto", NULL);
    add_htmode_choice(list, "HT20", "20 MHz", htmodes);
    add_htmode_choice(list, "HT40", "40 MHz", htmodes);
    add_htmode_choice(list, "VHT20", "20 MHz", htmodes);
    add_htmode_choice(list, "VHT40", "40 MHz", htmodes);
    add_htmode_choice(list, "VHT80", "80 MHz", htmodes);
    add_htmode_choice(list, "VHT80+80", "80+80 MHz", htmodes);
    add_htmode_choice(list, "VHT160", "160 MHz", htmodes);
    add_htmode_choice(list, "HE20", "20 MHz", htmodes);
    add_htmode_choice(list, "HE40", "40 MHz", htmodes);
    add_htmode_choice(list, "HE80", "80 MHz", htmodes);
    add_htmode_choice(list, "HE80+80", "80+80 MHz", htmodes);
    add_htmode_choice(list, "HE160", "160 MHz", htmodes);
    add_htmode_choice(list, "EHT20", "20 MHz", htmodes);
    add_htmode_choice(list, "EHT40", "40 MHz", htmodes);
    add_htmode_choice(list, "EHT80", "80 MHz", htmodes);
    add_htmode_choice(list, "EHT160", "160 MHz", htmodes);
    add_htmode_choice(list, "EHT320", "320 MHz", htmodes);

    if (iwinfo) {
        json_object_put(iwinfo);
    }
    return list;
}

static struct json_object *build_iwinfo_string_array(const char *radio_name, const char *name)
{
    struct json_object *list = NULL;
    struct json_object *iwinfo = NULL;
    struct json_object *values = NULL;
    int i = 0;

    list = json_object_new_array();
    if (!list) {
        return NULL;
    }

    iwinfo = get_radio_status_iwinfo(radio_name);
    if (!iwinfo) {
        iwinfo = get_radio_info_iwinfo(radio_name);
    }
    if (!iwinfo) {
        return list;
    }

    if (json_object_object_get_ex(iwinfo, name, &values) && values &&
        json_object_is_type(values, json_type_array)) {
        for (i = 0; i < json_object_array_length(values); i++) {
            struct json_object *value = json_object_array_get_idx(values, i);
            const char *str = value ? json_object_get_string(value) : NULL;
            if (str && str[0]) {
                json_object_array_add(list, json_object_new_string(str));
            }
        }
    }

    json_object_put(iwinfo);
    return list;
}

static int parse_wireless_encryption(const char *value, char *base, size_t size)
{
    char *cipher;
    if (!value || strlen(value) >= size) {
        return -1;
    }
    snprintf(base, size, "%s", value);
    cipher = strchr(base, '+');
    if (cipher) {
        *cipher++ = '\0';
        if (strcmp(cipher, "ccmp") && strcmp(cipher, "aes") && strcmp(cipher, "tkip") &&
            strcmp(cipher, "tkip+ccmp") && strcmp(cipher, "ccmp+tkip") &&
            strcmp(cipher, "tkip+aes") && strcmp(cipher, "aes+tkip")) {
            return -1;
        }
        if ((!strcmp(base, "none") || !strcmp(base, "owe")) ||
            (!strncmp(base, "sae", 3) && strcmp(cipher, "ccmp") && strcmp(cipher, "aes"))) {
            return -1;
        }
    }
    if (!strcmp(base, "none") || !strcmp(base, "owe") || !strcmp(base, "psk") ||
        !strcmp(base, "psk2") || !strcmp(base, "psk-mixed") || !strcmp(base, "sae") ||
        !strcmp(base, "sae-mixed")) {
        return 0;
    }
    return -1;
}

static int valid_wireless_password(const char *base, const char *password)
{
    size_t len = strlen(password), i;
    if (is_open_encryption(base)) return 1;
    if (!strcmp(base, "sae")) {
        return len >= 1 && len <= 63;
    } else if (len != 64 || !strncmp(base, "sae", 3)) {
        return len >= 8 && len <= 63;
    }
    for (i = 0; i < len; i++) {
        if (!isxdigit((unsigned char)password[i])) return 0;
    }
    return 1;
}

static int valid_wireless_text(struct json_object *value, size_t min, size_t max)
{
    const unsigned char *text;
    size_t len, i;
    if (!value || !json_object_is_type(value, json_type_string)) {
        return 0;
    }
    text = (const unsigned char *)json_object_get_string(value);
    len = json_object_get_string_len(value);
    if (len < min || len > max || strlen((const char *)text) != len) {
        return 0;
    }
    for (i = 0; i < len; i++) {
        if (text[i] < 32 || text[i] == 127) {
            return 0;
        }
    }
    return 1;
}

static int valid_wireless_bool_value(struct json_object *value)
{
    if (!value) return 1;
    if (json_object_is_type(value, json_type_boolean)) return 1;
    if (json_object_is_type(value, json_type_int)) {
        return json_object_get_int(value) == 0 || json_object_get_int(value) == 1;
    }
    if (json_object_is_type(value, json_type_string)) {
        const char *str = json_object_get_string(value);
        return str && (!strcmp(str, "0") || !strcmp(str, "1"));
    }
    return 0;
}

static int validate_ssid_item(struct uci_context *ctx, struct json_object *item,
                              char iface_names[][MAX_WIRELESS_NAME_LEN], int iface_num, int features)
{
    struct json_object *value;
    char iface[64] = {0}, radio[64] = {0}, first[64] = {0}, mode[16], wds[8];
    char encryption[64], base[64], key[128], band[16];
    const char *password;
    const char *flags[] = { "hidden", "isolate", "disabled" };
    size_t i;

    if (!item || !json_object_is_type(item, json_type_object)) {
        return -1;
    }
    value = json_object_object_get(item, "section");
    if (value) {
        if (!valid_wireless_text(value, 1, sizeof(iface) - 1)) return -1;
        snprintf(iface, sizeof(iface), "%s", json_object_get_string(value));
        if (!is_iface_exists(iface_names, iface_num, iface)) return -1;
        get_wireless_option_value(ctx, iface, "device", radio, sizeof(radio));
    }
    value = json_object_object_get(item, "radio");
    if (value) {
        if (!valid_wireless_text(value, 1, sizeof(radio) - 1)) return -1;
        if (radio[0] && strcmp(radio, json_object_get_string(value))) return -1;
        snprintf(radio, sizeof(radio), "%s", json_object_get_string(value));
    }
    if (!radio[0] || find_first_iface_by_radio(ctx, radio, iface_names, iface_num, first, sizeof(first))) return -1;
    if (iface[0] && strcmp(iface, first)) return -1;
    get_wireless_option_value(ctx, first, "mode", mode, sizeof(mode));
    get_wireless_option_value(ctx, first, "wds", wds, sizeof(wds));
    if (strcmp(mode, "ap") || parse_hidden_value(wds)) return -1;
    if (json_object_object_get(item, "mode") || json_object_object_get(item, "network")) return -1;
    for (i = 0; i < sizeof(flags) / sizeof(flags[0]); i++) {
        value = json_object_object_get(item, flags[i]);
        if (value && !valid_wireless_bool_value(value)) return -1;
    }

    value = json_object_object_get(item, "ssid");
    if (value && !valid_wireless_text(value, 1, 32)) return -1;
    get_wireless_option_value(ctx, first, "encryption", encryption, sizeof(encryption));
    if (!encryption[0]) snprintf(encryption, sizeof(encryption), "none");
    if (parse_wireless_encryption(encryption, base, sizeof(base))) return -1;
    value = json_object_object_get(item, "encryption");
    if (value) {
        if (!valid_wireless_text(value, 1, sizeof(encryption) - 1)) return -1;
        snprintf(encryption, sizeof(encryption), "%s", json_object_get_string(value));
    }
    if (parse_wireless_encryption(encryption, base, sizeof(base))) return -1;
    if (!strncmp(base, "psk", 3) && !(features & 1)) return -1;
    if (!strncmp(base, "sae", 3) && !(features & 2)) return -1;
    if (!strcmp(base, "owe") && !(features & 4)) return -1;
    get_wireless_option_value(ctx, radio, "band", band, sizeof(band));
    if (!strcmp(band, "6g") && strcmp(base, "sae") && strcmp(base, "owe")) return -1;

    value = json_object_object_get(item, "password");
    if (value && !valid_wireless_text(value, 0, 64)) return -1;
    if (!value && !is_open_encryption(base)) {
        char previous[64] = {0};
        get_wireless_option_value(ctx, first, "encryption", previous, sizeof(previous));
        if (strcmp(previous, encryption)) return -1;
    }
    get_wireless_option_value(ctx, first, "key", key, sizeof(key));
    password = value ? json_object_get_string(value) : key;
    return valid_wireless_password(base, password) ? 0 : -1;
}

static int valid_wireless_radio_item(struct json_object *item)
{
    struct json_object *value = NULL;
    const char *str = NULL;
    size_t len = 0, i = 0;

    value = json_object_object_get(item, "channel");
    if (value) {
        if (!json_object_is_type(value, json_type_string)) return -1;
        str = json_object_get_string(value);
        if (str && str[0] && strcmp(str, "auto")) {
            for (i = 0; str[i]; i++) {
                if (!isdigit((unsigned char)str[i])) return -1;
            }
            if (atoi(str) < 1 || atoi(str) > 233) return -1;
        }
    }

    value = json_object_object_get(item, "country");
    if (value) {
        if (!json_object_is_type(value, json_type_string)) return -1;
        str = json_object_get_string(value);
        len = str ? strlen(str) : 0;
        if (len && strcmp(str, "00") && !(len == 2 && isalpha((unsigned char)str[0]) && isalpha((unsigned char)str[1]))) return -1;
    }

    value = json_object_object_get(item, "htmode");
    if (value) {
        if (!json_object_is_type(value, json_type_string)) return -1;
        str = json_object_get_string(value);
        len = str ? strlen(str) : 0;
        if (len) {
            if (len >= 16) return -1;
            if (strcmp(str, "NOHT") && strncmp(str, "HT", 2) && strncmp(str, "VHT", 3) &&
                strncmp(str, "HE", 2) && strncmp(str, "EHT", 3)) return -1;
            for (i = 0; i < len; i++) {
                if (!isalnum((unsigned char)str[i]) && str[i] != '+' && str[i] != '-') return -1;
            }
        }
    }

    value = json_object_object_get(item, "hwmode");
    if (value) {
        if (!json_object_is_type(value, json_type_string)) return -1;
        str = json_object_get_string(value);
        if (str && str[0] && strcmp(str, "legacy") && strcmp(str, "n") &&
            strcmp(str, "ac") && strcmp(str, "ax") && strcmp(str, "be")) return -1;
    }

    value = json_object_object_get(item, "disabled");
    if (value && !valid_wireless_bool_value(value)) return -1;

    return 0;
}

static int validate_ssid_list(struct uci_context *ctx, struct json_object *list,
                              char radio_names[][MAX_WIRELESS_NAME_LEN], int radio_num,
                              char iface_names[][MAX_WIRELESS_NAME_LEN], int iface_num, int features)
{
    size_t i, count;
    if (json_object_is_type(list, json_type_array)) {
        count = json_object_array_length(list);
        if (!count || count > MAX_WIRELESS_SECTION_NUM) return -1;
        for (i = 0; i < count; i++) {
            struct json_object *item = json_object_array_get_idx(list, i);
            struct json_object *radio_obj = NULL;
            if (!item || !json_object_is_type(item, json_type_object)) return -1;
            radio_obj = json_object_object_get(item, "radio");
            if (radio_obj && (!valid_wireless_text(radio_obj, 1, MAX_WIRELESS_NAME_LEN - 1) ||
                !is_radio_exists(radio_names, radio_num, json_object_get_string(radio_obj)))) return -1;
            if (validate_ssid_item(ctx, item, iface_names, iface_num, features)) return -1;
        }
    } else {
        count = json_object_object_length(list);
        if (!count || count > MAX_WIRELESS_SECTION_NUM) return -1;
        json_object_object_foreach(list, name, item) {
            (void)name;
            struct json_object *radio_obj = NULL;
            if (!item || !json_object_is_type(item, json_type_object)) return -1;
            radio_obj = json_object_object_get(item, "radio");
            if (radio_obj && (!valid_wireless_text(radio_obj, 1, MAX_WIRELESS_NAME_LEN - 1) ||
                !is_radio_exists(radio_names, radio_num, json_object_get_string(radio_obj)))) return -1;
            if (validate_ssid_item(ctx, item, iface_names, iface_num, features)) return -1;
        }
    }
    return 0;
}

static int validate_radio_list(struct json_object *list,
                               char radio_names[][MAX_WIRELESS_NAME_LEN], int radio_num)
{
    size_t i = 0, count = 0;

    if (json_object_is_type(list, json_type_array)) {
        count = json_object_array_length(list);
        if (!count || count > MAX_WIRELESS_SECTION_NUM) return -1;
        for (i = 0; i < count; i++) {
            struct json_object *item = json_object_array_get_idx(list, i);
            struct json_object *radio_obj = NULL;
            if (!item || !json_object_is_type(item, json_type_object)) return -1;
            radio_obj = json_object_object_get(item, "radio");
            if (!radio_obj || !valid_wireless_text(radio_obj, 1, MAX_WIRELESS_NAME_LEN - 1) ||
                !is_radio_exists(radio_names, radio_num, json_object_get_string(radio_obj))) return -1;
            if (valid_wireless_radio_item(item)) return -1;
        }
        return 0;
    }

    count = json_object_object_length(list);
    if (!count || count > MAX_WIRELESS_SECTION_NUM) return -1;
    json_object_object_foreach(list, name, item) {
        struct json_object *radio_obj = NULL;
        (void)name;
        if (!item || !json_object_is_type(item, json_type_object)) return -1;
        radio_obj = json_object_object_get(item, "radio");
        if (!radio_obj || !valid_wireless_text(radio_obj, 1, MAX_WIRELESS_NAME_LEN - 1) ||
            !is_radio_exists(radio_names, radio_num, json_object_get_string(radio_obj))) return -1;
        if (valid_wireless_radio_item(item)) return -1;
    }

    return 0;
}

static int apply_radio_item(struct uci_context *ctx, struct json_object *item,
                            char iface_names[][MAX_WIRELESS_NAME_LEN], int iface_num)
{
    struct json_object *radio_obj = NULL, *channel_obj = NULL, *country_obj = NULL, *htmode_obj = NULL, *disabled_obj = NULL;
    const char *radio_name = NULL;
    char iface_name[MAX_WIRELESS_NAME_LEN] = {0};
    int has_change = 0;

    if (!ctx || !item || json_object_get_type(item) != json_type_object) {
        return 0;
    }

    json_object_object_get_ex(item, "radio", &radio_obj);
    json_object_object_get_ex(item, "channel", &channel_obj);
    json_object_object_get_ex(item, "country", &country_obj);
    json_object_object_get_ex(item, "htmode", &htmode_obj);
    json_object_object_get_ex(item, "disabled", &disabled_obj);
    radio_name = radio_obj ? json_object_get_string(radio_obj) : NULL;
    if (!radio_name || !radio_name[0]) {
        return 0;
    }

    if (channel_obj) {
        const char *channel = json_object_get_string(channel_obj);
        if (set_wireless_option_value(ctx, radio_name, "channel", channel && channel[0] ? channel : "auto") == 0) has_change = 1;
        else return -1;
    }
    if (country_obj) {
        const char *country = json_object_get_string(country_obj);
        if (country && country[0]) {
            if (set_wireless_option_value(ctx, radio_name, "country", country) == 0) has_change = 1;
            else return -1;
        } else if (delete_wireless_option_value(ctx, radio_name, "country") == 0) {
            has_change = 1;
        } else {
            return -1;
        }
    }
    if (htmode_obj) {
        const char *htmode = json_object_get_string(htmode_obj);
        if (htmode && htmode[0]) {
            if (set_wireless_option_value(ctx, radio_name, "htmode", htmode) == 0) has_change = 1;
            else return -1;
        } else if (delete_wireless_option_value(ctx, radio_name, "htmode") == 0) {
            has_change = 1;
        } else {
            return -1;
        }
    }
    if (disabled_obj) {
        int disabled = json_to_bool(disabled_obj, 0);
        char disabled_str[4] = {0};
        snprintf(disabled_str, sizeof(disabled_str), "%d", disabled ? 1 : 0);
        if (set_wireless_option_value(ctx, radio_name, "disabled", disabled_str) == 0) has_change = 1;
        else return -1;
        if (find_first_iface_by_radio(ctx, radio_name, iface_names, iface_num, iface_name, sizeof(iface_name)) == 0) {
            if (set_wireless_option_value(ctx, iface_name, "disabled", disabled_str) == 0) has_change = 1;
            else return -1;
        }
    }

    return has_change;
}

static int apply_ssid_item(struct uci_context *ctx, struct json_object *item,
                           char iface_names[][MAX_WIRELESS_NAME_LEN], int iface_num)
{
    struct json_object *radio_obj = NULL;
    struct json_object *section_obj = NULL;
    struct json_object *ssid_obj = NULL;
    struct json_object *password_obj = NULL;
    struct json_object *encryption_obj = NULL;
    struct json_object *hidden_obj = NULL;
    struct json_object *isolate_obj = NULL;
    struct json_object *disabled_obj = NULL;
    const char *radio_name = NULL;
    const char *section_name = NULL;
    const char *password = NULL;
    char encryption[64] = {0};
    char iface_name[MAX_WIRELESS_NAME_LEN] = {0};
    char radio_name_buf[MAX_WIRELESS_NAME_LEN] = {0};
    int has_password = 0;
    int has_encryption = 0;
    int has_change = 0;
    int hidden = 0;
    int isolate = 0;
    int disabled = 0;
    char hidden_str[4] = {0};
    char isolate_str[4] = {0};
    char disabled_str[4] = {0};

    if (!ctx || !item || json_object_get_type(item) != json_type_object) {
        return 0;
    }

    json_object_object_get_ex(item, "radio", &radio_obj);
    json_object_object_get_ex(item, "section", &section_obj);
    json_object_object_get_ex(item, "ssid", &ssid_obj);
    has_password = json_object_object_get_ex(item, "password", &password_obj);
    has_encryption = json_object_object_get_ex(item, "encryption", &encryption_obj);
    json_object_object_get_ex(item, "hidden", &hidden_obj);
    json_object_object_get_ex(item, "isolate", &isolate_obj);
    json_object_object_get_ex(item, "disabled", &disabled_obj);

    radio_name = radio_obj ? json_object_get_string(radio_obj) : NULL;
    section_name = section_obj ? json_object_get_string(section_obj) : NULL;

    if (section_name && section_name[0] != '\0' && is_iface_exists(iface_names, iface_num, section_name)) {
        snprintf(iface_name, sizeof(iface_name), "%s", section_name);
    }

    if (iface_name[0] == '\0' && radio_name && radio_name[0] != '\0') {
        find_first_iface_by_radio(ctx, radio_name, iface_names, iface_num, iface_name, sizeof(iface_name));
    }

    if (iface_name[0] == '\0') {
        LOG_WARN("set_wireless_interface_info skip item, iface not found, radio=%s section=%s\n",
                 radio_name ? radio_name : "", section_name ? section_name : "");
        return 0;
    }
    if ((!radio_name || !radio_name[0]) &&
        get_wireless_option_value(ctx, iface_name, "device", radio_name_buf, sizeof(radio_name_buf)) == 0) {
        radio_name = radio_name_buf;
    }
    if (ssid_obj) {
        const char *ssid = json_object_get_string(ssid_obj);
        if (set_wireless_option_value(ctx, iface_name, "ssid", ssid ? ssid : "") == 0) {
            has_change = 1;
        } else {
            return -1;
        }
    }

    if (has_encryption) {
        const char *enc_value = json_object_get_string(encryption_obj);
        char previous[64] = {0};
        get_wireless_option_value(ctx, iface_name, "encryption", previous, sizeof(previous));
        if (!enc_value || enc_value[0] == '\0') {
            enc_value = "none";
        }
        snprintf(encryption, sizeof(encryption), "%s", enc_value);
        if (strcmp(previous, encryption) && delete_wireless_option_value(ctx, iface_name, "ieee80211w") != 0) {
            return -1;
        }
        if (set_wireless_option_value(ctx, iface_name, "encryption", encryption) == 0) {
            has_change = 1;
        } else {
            return -1;
        }
    } else {
        if (get_wireless_option_value(ctx, iface_name, "encryption", encryption, sizeof(encryption)) != 0 ||
            encryption[0] == '\0') {
            snprintf(encryption, sizeof(encryption), "none");
        }
    }

    if (hidden_obj) {
        hidden = json_to_bool(hidden_obj, 0);
        snprintf(hidden_str, sizeof(hidden_str), "%d", hidden ? 1 : 0);
        if (set_wireless_option_value(ctx, iface_name, "hidden", hidden_str) == 0) {
            has_change = 1;
        } else {
            return -1;
        }
    }
    if (isolate_obj) {
        isolate = json_to_bool(isolate_obj, 0);
        snprintf(isolate_str, sizeof(isolate_str), "%d", isolate ? 1 : 0);
        if (set_wireless_option_value(ctx, iface_name, "isolate", isolate_str) == 0) {
            has_change = 1;
        } else {
            return -1;
        }
    }
    if (disabled_obj) {
        disabled = json_to_bool(disabled_obj, 0);
        snprintf(disabled_str, sizeof(disabled_str), "%d", disabled ? 1 : 0);
        if (set_wireless_option_value(ctx, iface_name, "disabled", disabled_str) == 0) {
            has_change = 1;
        } else {
            return -1;
        }
        if (radio_name && radio_name[0]) {
            if (set_wireless_option_value(ctx, radio_name, "disabled", disabled_str) == 0) {
                has_change = 1;
            } else {
                return -1;
            }
        }
    }

    if (is_open_encryption(encryption)) {
        int del_key = delete_wireless_option_value(ctx, iface_name, "key");
        int del_key1 = delete_wireless_option_value(ctx, iface_name, "key1");
        if (del_key != 0 || del_key1 != 0) return -1;
        has_change = 1;
    } else if (has_password) {
        password = json_object_get_string(password_obj);
        if (password && password[0] != '\0') {
            if (set_wireless_option_value(ctx, iface_name, "key", password) == 0) {
                has_change = 1;
            } else {
                return -1;
            }
        } else {
            if (delete_wireless_option_value(ctx, iface_name, "key") == 0) {
                has_change = 1;
            } else {
                return -1;
            }
        }
    }

    return has_change;
}

struct json_object *fwx_api_get_wireless_interface_info(struct json_object *req_obj)
{
    struct uci_context *ctx = NULL;
    struct json_object *data_obj = NULL;
    struct json_object *ssid_list_obj = NULL;
    char radio_names[MAX_WIRELESS_SECTION_NUM][MAX_WIRELESS_NAME_LEN] = {{0}};
    char iface_names[MAX_WIRELESS_SECTION_NUM][MAX_WIRELESS_NAME_LEN] = {{0}};
    int radio_num = 0;
    int iface_num = 0;
    int i = 0;

    (void)req_obj;

    data_obj = json_object_new_object();
    ssid_list_obj = json_object_new_array();
    if (!data_obj || !ssid_list_obj) {
        if (ssid_list_obj) {
            json_object_put(ssid_list_obj);
        }
        if (data_obj) {
            json_object_put(data_obj);
        }
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    ctx = uci_alloc_context();
    if (!ctx) {
        json_object_put(ssid_list_obj);
        json_object_put(data_obj);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    if (collect_wireless_sections(ctx, radio_names, &radio_num, iface_names, &iface_num) != 0) {
        uci_free_context(ctx);
        json_object_put(ssid_list_obj);
        json_object_put(data_obj);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    for (i = 0; i < radio_num; i++) {
        struct json_object *ssid_obj = NULL;
        char iface_name[MAX_WIRELESS_NAME_LEN] = {0};
        char ssid[128] = {0};
        char key[128] = {0};
        char encryption[64] = {0};
        char hidden[16] = {0};
        char isolate[16] = {0};
        char band[16] = {0};
        char hwmode[32] = {0};
        char band_label[16] = {0};
        char mode[16] = {0}, wds[8] = {0}, disabled[8] = {0}, radio_disabled[8] = {0};
        char base[64] = {0};

        find_first_iface_by_radio(ctx, radio_names[i], iface_names, iface_num, iface_name, sizeof(iface_name));

        get_wireless_option_value(ctx, iface_name, "ssid", ssid, sizeof(ssid));
        get_wireless_option_value(ctx, iface_name, "encryption", encryption, sizeof(encryption));
        get_wireless_option_value(ctx, iface_name, "key", key, sizeof(key));
        get_wireless_option_value(ctx, iface_name, "hidden", hidden, sizeof(hidden));
        get_wireless_option_value(ctx, iface_name, "isolate", isolate, sizeof(isolate));
        get_wireless_option_value(ctx, radio_names[i], "band", band, sizeof(band));
        get_wireless_option_value(ctx, radio_names[i], "hwmode", hwmode, sizeof(hwmode));
        get_wireless_option_value(ctx, iface_name, "mode", mode, sizeof(mode));
        get_wireless_option_value(ctx, iface_name, "wds", wds, sizeof(wds));
        get_wireless_option_value(ctx, iface_name, "disabled", disabled, sizeof(disabled));
        get_wireless_option_value(ctx, radio_names[i], "disabled", radio_disabled, sizeof(radio_disabled));

        ssid_obj = json_object_new_object();
        if (!ssid_obj) {
            continue;
        }

        json_object_object_add(ssid_obj, "radio", json_object_new_string(radio_names[i]));
        json_object_object_add(ssid_obj, "section", json_object_new_string(iface_name));
        json_object_object_add(ssid_obj, "band", json_object_new_string(format_band_label(band, hwmode, band_label, sizeof(band_label))));
        json_object_object_add(ssid_obj, "ssid", json_object_new_string(ssid));
        json_object_object_add(ssid_obj, "password", json_object_new_string(key));
        json_object_object_add(ssid_obj, "encryption", json_object_new_string(encryption[0] ? encryption : "none"));
        json_object_object_add(ssid_obj, "hidden", json_object_new_int(parse_hidden_value(hidden)));
        json_object_object_add(ssid_obj, "isolate", json_object_new_int(parse_hidden_value(isolate)));
        json_object_object_add(ssid_obj, "mode", json_object_new_string(mode));
        json_object_object_add(ssid_obj, "wds", json_object_new_int(parse_hidden_value(wds)));
        json_object_object_add(ssid_obj, "disabled", json_object_new_int(parse_hidden_value(disabled) || parse_hidden_value(radio_disabled)));
        json_object_object_add(ssid_obj, "read_only", json_object_new_boolean(!iface_name[0] || strcmp(mode, "ap") ||
            parse_hidden_value(wds) || parse_wireless_encryption(encryption[0] ? encryption : "none", base, sizeof(base))));
        json_object_array_add(ssid_list_obj, ssid_obj);
    }

    json_object_object_add(data_obj, "ssid_list", ssid_list_obj);
    json_object_object_add(data_obj, "security_features", json_object_new_int(wireless_security_features()));
    uci_free_context(ctx);

    return fwx_gen_api_response_data(API_CODE_SUCCESS, data_obj);
}

struct json_object *fwx_api_get_wireless_radio_info(struct json_object *req_obj)
{
    struct uci_context *ctx = NULL;
    struct json_object *data_obj = NULL;
    struct json_object *radio_list_obj = NULL;
    char radio_names[MAX_WIRELESS_SECTION_NUM][MAX_WIRELESS_NAME_LEN] = {{0}};
    char iface_names[MAX_WIRELESS_SECTION_NUM][MAX_WIRELESS_NAME_LEN] = {{0}};
    int radio_num = 0, iface_num = 0, i = 0;

    (void)req_obj;

    data_obj = json_object_new_object();
    radio_list_obj = json_object_new_array();
    if (!data_obj || !radio_list_obj) {
        if (radio_list_obj) json_object_put(radio_list_obj);
        if (data_obj) json_object_put(data_obj);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    ctx = uci_alloc_context();
    if (!ctx) {
        json_object_put(radio_list_obj);
        json_object_put(data_obj);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }
    if (collect_wireless_sections(ctx, radio_names, &radio_num, iface_names, &iface_num) != 0) {
        uci_free_context(ctx);
        json_object_put(radio_list_obj);
        json_object_put(data_obj);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    for (i = 0; i < radio_num; i++) {
        struct json_object *radio_obj = json_object_new_object();
        char iface_name[MAX_WIRELESS_NAME_LEN] = {0};
        char band[16] = {0}, hwmode[32] = {0}, channel[16] = {0};
        char country[8] = {0}, htmode[16] = {0}, disabled[8] = {0}, iface_disabled[8] = {0};
        char band_label[16] = {0}, current_hwmode[16] = {0};

        if (!radio_obj) continue;
        get_wireless_option_value(ctx, radio_names[i], "band", band, sizeof(band));
        get_wireless_option_value(ctx, radio_names[i], "hwmode", hwmode, sizeof(hwmode));
        get_wireless_option_value(ctx, radio_names[i], "channel", channel, sizeof(channel));
        get_wireless_option_value(ctx, radio_names[i], "country", country, sizeof(country));
        get_wireless_option_value(ctx, radio_names[i], "htmode", htmode, sizeof(htmode));
        get_wireless_option_value(ctx, radio_names[i], "disabled", disabled, sizeof(disabled));
        if (find_first_iface_by_radio(ctx, radio_names[i], iface_names, iface_num, iface_name, sizeof(iface_name)) == 0) {
            get_wireless_option_value(ctx, iface_name, "disabled", iface_disabled, sizeof(iface_disabled));
        }

        json_object_object_add(radio_obj, "radio", json_object_new_string(radio_names[i]));
        json_object_object_add(radio_obj, "band", json_object_new_string(format_band_label(band, hwmode, band_label, sizeof(band_label))));
        json_object_object_add(radio_obj, "channel", json_object_new_string(channel[0] ? channel : "auto"));
        json_object_object_add(radio_obj, "country", json_object_new_string(country));
        json_object_object_add(radio_obj, "htmode", json_object_new_string(htmode));
        json_object_object_add(radio_obj, "hwmode", json_object_new_string(get_current_radio_hwmode(radio_names[i], htmode, hwmode, current_hwmode, sizeof(current_hwmode))));
        json_object_object_add(radio_obj, "disabled", json_object_new_int(parse_hidden_value(disabled) || parse_hidden_value(iface_disabled)));
        json_object_object_add(radio_obj, "channel_list", build_iwinfo_channel_list(radio_names[i], band));
        json_object_object_add(radio_obj, "country_list", build_iwinfo_country_list(radio_names[i]));
        json_object_object_add(radio_obj, "htmode_list", build_iwinfo_htmode_list(radio_names[i]));
        json_object_object_add(radio_obj, "hwmode_list", build_iwinfo_string_array(radio_names[i], "hwmodes"));
        json_object_object_add(radio_obj, "acs_supported", json_object_new_boolean(wireless_acs_supported()));
        json_object_array_add(radio_list_obj, radio_obj);
    }

    json_object_object_add(data_obj, "radio_list", radio_list_obj);
    uci_free_context(ctx);
    return fwx_gen_api_response_data(API_CODE_SUCCESS, data_obj);
}

struct json_object *fwx_api_set_wireless_radio_info(struct json_object *req_obj)
{
    struct uci_context *ctx = NULL;
    struct json_object *radio_list_obj = NULL;
    enum json_type radio_list_type;
    char radio_names[MAX_WIRELESS_SECTION_NUM][MAX_WIRELESS_NAME_LEN] = {{0}};
    char iface_names[MAX_WIRELESS_SECTION_NUM][MAX_WIRELESS_NAME_LEN] = {{0}};
    int radio_num = 0, iface_num = 0, i = 0, list_len = 0, has_change = 0;

    if (!req_obj) return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    radio_list_obj = json_object_object_get(req_obj, "radio_list");
    if (!radio_list_obj) return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    radio_list_type = json_object_get_type(radio_list_obj);
    if (radio_list_type != json_type_array && radio_list_type != json_type_object) {
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    ctx = uci_alloc_context();
    if (!ctx) return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    if (collect_wireless_sections(ctx, radio_names, &radio_num, iface_names, &iface_num) != 0 ||
        validate_radio_list(radio_list_obj, radio_names, radio_num) != 0) {
        uci_free_context(ctx);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    if (radio_list_type == json_type_array) {
        list_len = json_object_array_length(radio_list_obj);
        for (i = 0; i < list_len; i++) {
            has_change |= apply_radio_item(ctx, json_object_array_get_idx(radio_list_obj, i), iface_names, iface_num);
            if (has_change < 0) break;
        }
    } else {
        json_object_object_foreach(radio_list_obj, key, val) {
            (void)key;
            has_change |= apply_radio_item(ctx, val, iface_names, iface_num);
            if (has_change < 0) break;
        }
    }

    if (has_change < 0) {
        uci_free_context(ctx);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }
    if (has_change) {
        if (fwx_uci_commit(ctx, "wireless") != UCI_OK) {
            uci_free_context(ctx);
            return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
        }
        system("(sleep 2; /sbin/wifi reload) >/dev/null 2>&1 &");
    }

    uci_free_context(ctx);
    return fwx_gen_api_response_data(API_CODE_SUCCESS, NULL);
}

struct json_object *fwx_api_set_wireless_interface_info(struct json_object *req_obj)
{
    struct uci_context *ctx = NULL;
    struct json_object *ssid_list_obj = NULL;
    enum json_type ssid_list_type;
    char radio_names[MAX_WIRELESS_SECTION_NUM][MAX_WIRELESS_NAME_LEN] = {{0}};
    char iface_names[MAX_WIRELESS_SECTION_NUM][MAX_WIRELESS_NAME_LEN] = {{0}};
    int radio_num = 0;
    int iface_num = 0;
    int i = 0;
    int list_len = 0;
    int has_change = 0;
    int processed_num = 0;

    if (!req_obj) {
        LOG_ERROR("set_wireless_interface_info: req_obj is null\n");
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    ssid_list_obj = json_object_object_get(req_obj, "ssid_list");
    if (!ssid_list_obj) {
        LOG_ERROR("set_wireless_interface_info: missing ssid_list\n");
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }
    ssid_list_type = json_object_get_type(ssid_list_obj);
    if (ssid_list_type != json_type_array && ssid_list_type != json_type_object) {
        LOG_ERROR("set_wireless_interface_info: invalid ssid_list type=%d\n", ssid_list_type);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    ctx = uci_alloc_context();
    if (!ctx) {
        LOG_ERROR("set_wireless_interface_info: alloc uci ctx failed\n");
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    if (collect_wireless_sections(ctx, radio_names, &radio_num, iface_names, &iface_num) != 0) {
        LOG_ERROR("set_wireless_interface_info: collect_wireless_sections failed\n");
        uci_free_context(ctx);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    if (validate_ssid_list(ctx, ssid_list_obj, radio_names, radio_num, iface_names, iface_num, wireless_security_features())) {
        uci_free_context(ctx);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }

    if (ssid_list_type == json_type_array) {
        list_len = json_object_array_length(ssid_list_obj);
        for (i = 0; i < list_len; i++) {
            struct json_object *item = json_object_array_get_idx(ssid_list_obj, i);
            has_change |= apply_ssid_item(ctx, item, iface_names, iface_num);
            if (has_change < 0) break;
            processed_num++;
        }
    } else {
        json_object_object_foreach(ssid_list_obj, key, val) {
            (void)key;
            has_change |= apply_ssid_item(ctx, val, iface_names, iface_num);
            if (has_change < 0) break;
            processed_num++;
        }
    }
    LOG_INFO("set_wireless_interface_info: list_type=%d processed=%d changed=%d\n",
             ssid_list_type, processed_num, has_change);

    if (has_change < 0) {
        uci_free_context(ctx);
        return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
    }
    if (has_change) {
        if (fwx_uci_commit(ctx, "wireless") != UCI_OK) {
            LOG_ERROR("set_wireless_interface_info: commit wireless failed\n");
            uci_free_context(ctx);
            return fwx_gen_api_response_data(API_CODE_ERROR, NULL);
        }
        system("(sleep 2; /sbin/wifi reload) >/dev/null 2>&1 &");
    }

    uci_free_context(ctx);

    return fwx_gen_api_response_data(API_CODE_SUCCESS, NULL);
}
