#include <stdint.h>
typedef struct {
    char name[32];
    uint32_t index;
    uint32_t flags;
    uint8_t type;
    uint64_t received;
    uint64_t sent;
} TrafficInterface;
// Returns required count (possibly greater than capacity), or a negative error.
// Writes at most capacity entries. Reads 64-bit kernel counters.
int traffic_interfaces(TrafficInterface *output, int capacity);

typedef struct {
    char name[32];
    char address[64];
} TrafficAddress;
// Local interface addresses only. Does not transmit or inspect packets.
int traffic_addresses(TrafficAddress *output, int capacity);
