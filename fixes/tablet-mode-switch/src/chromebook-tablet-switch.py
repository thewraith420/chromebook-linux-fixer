import fcntl, struct, os, time, signal
UI_SET_EVBIT=0x40045564; UI_SET_SWBIT=0x4004556d; UI_DEV_SETUP=0x405c5503; UI_DEV_CREATE=0x5501
EV_SYN=0x00; EV_SW=0x05; SW_TABLET_MODE=0x01; SYN_REPORT=0x00; BUS_VIRTUAL=0x06
fd=os.open("/dev/uinput", os.O_WRONLY|os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_SW)
fcntl.ioctl(fd, UI_SET_SWBIT, SW_TABLET_MODE)
name=b"PixelSlate Tablet Mode Switch"
setup=struct.pack("HHHH",BUS_VIRTUAL,0x18d1,0x5044,1)+name.ljust(80,b"\x00")+struct.pack("I",0)
fcntl.ioctl(fd, UI_DEV_SETUP, setup); fcntl.ioctl(fd, UI_DEV_CREATE); time.sleep(1)
def emit(t,c,v): os.write(fd, struct.pack("llHHi",0,0,t,c,v))
emit(EV_SW, SW_TABLET_MODE, 1); emit(EV_SYN, SYN_REPORT, 0)
signal.pause()
