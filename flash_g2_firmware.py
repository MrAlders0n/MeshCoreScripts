#!python3
import esptool
import time
import sys
import os
from pathlib import Path

def find_device(cycled: bool) -> str:
  print(f'Searching for a Station G2 connected via serial')
  serial_devices = os.listdir('/dev/serial/by-id')
  print('\n'.join(serial_devices))
  target_device = ''
  hints = ['Station_G2', "Espressif_USB_JTAG"]
  for dev in serial_devices:
    if any(hint in dev for hint in hints):
      target_device = dev
      print(f'Found a device: {dev}')
      break

  if target_device == '':
    print('No device found')
    if cycled == True:
      raise Exception('Unable to find a Station G2 attached to serial')
    print('Unable to find a Station G2 attached to serial. Attempting power cycle')
    find_device(hint, True)

  target_device = f'/dev/serial/by-id/{target_device}'
  print(f'Using {target_device}')
  return target_device

if __name__ == '__main__':
  if len(sys.argv) > 2:
    raise Exception('Missing argument containing path to firmware file')

  firmware = sys.argv[1]
  file = Path(firmware)
  if not file.is_file():
    raise Exception(f'{firmware} is not a valid file')

  dev = find_device(False)
  if "Station_G2" in dev:
    try:
      print('Entering bootloader mode via 1200 baud connection')
      cmd = ['--port', dev, '--baud', '1200', '--after', 'no_reset', 'chip_id']
      print(f'Executing command: esptool.py {" ".join(cmd)}')
      esptool.main(cmd)
    except Exception:
      pass
    finally:
      time.sleep(8)
  else:
    print('Station G2 is already in bootloader mode')

  dev = find_device(False)
  print(f'Updating firmware: {firmware}')
  cmd = ['--port', dev, 'write_flash', '0x10000', firmware]
  print(f'Executing command: esptool.py {" ".join(cmd)}')
  esptool.main(cmd)
  time.sleep(2)
