#include "CNetwork.h"
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <net/route.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

int traffic_interfaces(TrafficInterface *output, int capacity) {
    int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t size = 0;
    if (sysctl(mib, 6, NULL, &size, NULL, 0) != 0) return -errno;
    char *buffer = malloc(size);
    if (!buffer) return -1;
    if (sysctl(mib, 6, buffer, &size, NULL, 0) != 0) { int code = errno; free(buffer); return -code; }
    int count = 0;
    for (char *p = buffer; p + 4 <= buffer + size;) {
        struct if_msghdr *header = (struct if_msghdr *)p;
        if (header->ifm_msglen < 4 || p + header->ifm_msglen > buffer + size) {
            free(buffer); return -1;
        }
        if (header->ifm_type == RTM_IFINFO2 && header->ifm_msglen >= sizeof(struct if_msghdr2)) {
            struct if_msghdr2 *info = (struct if_msghdr2 *)p;
            TrafficInterface item = {0};
            if (if_indextoname(info->ifm_index, item.name)) {
                item.index = info->ifm_index;
                item.flags = info->ifm_flags;
                item.type = info->ifm_data.ifi_type;
                item.received = info->ifm_data.ifi_ibytes;
                item.sent = info->ifm_data.ifi_obytes;
                if (count < capacity) output[count] = item;
                count++;
            }
        }
        p += header->ifm_msglen;
    }
    free(buffer);
    return count;
}

#include <ifaddrs.h>
#include <arpa/inet.h>
int traffic_addresses(TrafficAddress *output, int capacity) {
    struct ifaddrs *addresses = NULL;
    if (getifaddrs(&addresses)) return -errno;
    int count = 0;
    for (struct ifaddrs *item = addresses; item; item = item->ifa_next) {
        if (!item->ifa_addr) continue;
        int family = item->ifa_addr->sa_family;
        const void *address = NULL;
        if (family == AF_INET) address = &((struct sockaddr_in *)item->ifa_addr)->sin_addr;
        if (family == AF_INET6) address = &((struct sockaddr_in6 *)item->ifa_addr)->sin6_addr;
        if (!address) continue;
        if (count == capacity) { freeifaddrs(addresses); return -1; }
        TrafficAddress *out = &output[count]; memset(out, 0, sizeof(*out));
        strlcpy(out->name, item->ifa_name, sizeof(out->name));
        if (inet_ntop(family, address, out->address, sizeof(out->address))) count++;
    }
    freeifaddrs(addresses); return count;
}
