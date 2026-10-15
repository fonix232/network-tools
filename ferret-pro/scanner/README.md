# CR-Scan Ferret Pro scanner head: firmware analysis (work in progress)

Early notes; being expanded.

- Image `MX6600_CRScan_Ferret_App_V1.2.7.bin` is firmware for the Orbbec MX6600 depth ASIC's embedded ARMv6-M core.
- USB: VID 0x2BC5 (Orbbec) PID 0x069C, composite UVC 1.1 device (depth / IR / colour) + HID (IMU).
- Bridge host stack is Orbbec SDK 1.7.1 (`libOrbbecSDK.so.1.7.1`, class `FerretUvcDevice`).
