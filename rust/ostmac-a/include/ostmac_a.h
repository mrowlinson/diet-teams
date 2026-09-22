#ifndef OSTMAC_A_H
#define OSTMAC_A_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* (request_id, utf8 json, context). json valid during the call only. */
typedef void (*ostmac_a_cb)(int64_t req_id, const char *json, void *ctx);

const char *ostmac_version(void);
int32_t ostmac_init(void);
void ostmac_auth_start(int64_t req_id, ostmac_a_cb cb, void *ctx);
void ostmac_chats(int64_t req_id, int32_t limit, ostmac_a_cb cb, void *ctx);
void ostmac_trouter_start(int64_t req_id, ostmac_a_cb cb, void *ctx);

#ifdef __cplusplus
}
#endif

#endif
