import {deviceInfo} from '@kit.BasicServicesKit';

export class DeviceUtils {
  static isEmulator(): boolean {
    return deviceInfo.productModel === 'emulator';
  }
}