@import Foundation;
@import IOKit;

#include "DDCBridge.h"
#include "i2c.h"
#include "ioregistry.h"

static void releaseDisplayInfos(DisplayInfos *displays, CGDisplayCount displayCount) {
    for (CGDisplayCount index = 0; index < displayCount; ++index) {
        if (displays[index].adapter != MACH_PORT_NULL) IOObjectRelease(displays[index].adapter);
        if (displays[index].uuid != nil) CFRelease((CFTypeRef)displays[index].uuid);
        if (displays[index].ioLocation != nil) CFRelease((CFTypeRef)displays[index].ioLocation);
        if (displays[index].edid != nil) CFRelease((CFTypeRef)displays[index].edid);
        if (displays[index].productName != nil) CFRelease((CFTypeRef)displays[index].productName);
        if (displays[index].manufacturer != nil) CFRelease((CFTypeRef)displays[index].manufacturer);
        if (displays[index].alphNumSerial != nil) CFRelease((CFTypeRef)displays[index].alphNumSerial);
    }
}

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
            releaseDisplayInfos(displays, displayCount);
            return -2;
        }

        DDCTransport transport = getDisplayDDCTransport(target);
        if (transport.service == NULL) {
            releaseDisplayInfos(displays, displayCount);
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
        releaseDisplayInfos(displays, displayCount);
        return result == kIOReturnSuccess ? 0 : (int32_t)result;
    }
}
