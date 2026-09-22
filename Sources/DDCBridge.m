@import Foundation;
@import IOKit;

#include "DDCBridge.h"
#include "i2c.h"
#include "ioregistry.h"

int32_t KVMLinkSetLGInput(const char *displayUUID, uint16_t inputValue) {
    @autoreleasepool {
        if (displayUUID == NULL) {
            return -1;
        }

        DisplayInfos displays[MAX_DISPLAYS] = {};
        const CGDisplayCount displayCount = getOnlineDisplayInfos(displays);
        NSString *targetUUID = [NSString stringWithUTF8String:displayUUID];
        DisplayInfos *target = NULL;

        for (CGDisplayCount index = 0; index < displayCount; ++index) {
            if ([displays[index].uuid caseInsensitiveCompare:targetUUID] == NSOrderedSame) {
                target = displays + index;
                break;
            }
        }

        if (target == NULL) {
            for (CGDisplayCount index = 0; index < displayCount; ++index) {
                if (displays[index].adapter != MACH_PORT_NULL) {
                    IOObjectRelease(displays[index].adapter);
                }
            }
            return -2;
        }

        DDCTransport transport = getDisplayDDCTransport(target);
        if (transport.service == NULL) {
            for (CGDisplayCount index = 0; index < displayCount; ++index) {
                if (displays[index].adapter != MACH_PORT_NULL) {
                    IOObjectRelease(displays[index].adapter);
                }
            }
            return -3;
        }

        DDCPacket packet = createDDCPacket(INPUT_ALT);
        prepareDDCWrite(&packet, inputValue);
        const IOReturn result = performDDCWriteAtChipAddress(
            transport.service,
            transport.chipAddress,
            &packet
        );

        CFRelease(transport.service);
        for (CGDisplayCount index = 0; index < displayCount; ++index) {
            if (displays[index].adapter != MACH_PORT_NULL) {
                IOObjectRelease(displays[index].adapter);
            }
        }
        return result == kIOReturnSuccess ? 0 : (int32_t)result;
    }
}
