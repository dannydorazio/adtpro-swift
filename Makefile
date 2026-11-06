# ADTPro build
#
#   make                 build the Swift package (host library + CLI)
#   make test            run the Swift test suite
#   make payloads        assemble the 6502 clients into the host's bootstrap payloads (needs cc65)
#   make disks           build the distribution client disk images (needs cc65)
#   make app             generate ADTPro.xcodeproj from project.yml and build the macOS app (needs xcodegen)
#   make linux-test      build and test inside a Linux container (needs docker)
#   make clean

VERSION     ?= 3.0.0
CA65        ?= ca65
LD65        ?= ld65
CL65        ?= cl65
SWIFT       ?= swift

ROOT        := $(abspath .)
CLIENT      := $(ROOT)/client
PREBUILT    := $(CLIENT)/prebuilt
BASEIMAGES  := $(CLIENT)/disks
CLIENTLIB   := $(CLIENT)/lib
OBJ         := $(ROOT)/.build/client
PAYLOADS    := $(ROOT)/Sources/ADTProCore/Resources/Payloads
DISKS       := $(ROOT)/.build/disks

IP65LIB     := $(CLIENTLIB)/ip65/ip65.lib $(CLIENTLIB)/ip65/a2combo.lib $(CLIENTLIB)/cc65/apple2.lib
IP65U2LIB   := $(CLIENTLIB)/ip65/ip65.lib $(CLIENTLIB)/ip65/a2uther2.lib $(CLIENTLIB)/cc65/apple2.lib

ADTPRO_CLI  := $(ROOT)/.build/release/adtpro

.PHONY: all build release test payloads disks app clean linux-test client-objects

all: build

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

test:
	$(SWIFT) test

# ---------------------------------------------------------------------------
# 6502 clients (sources in client/; base disks and link libraries in client/disks, client/lib)
# ---------------------------------------------------------------------------

BUILT_PAYLOADS := \
	$(PAYLOADS)/adtpro.raw \
	$(PAYLOADS)/adtproaud.raw \
	$(PAYLOADS)/adtproeth.raw \
	$(PAYLOADS)/grub2.bin \
	$(PAYLOADS)/grub_vsdrive.bin \
	$(PAYLOADS)/adt.raw \
	$(PAYLOADS)/vsdrive_speed.raw \
	$(PAYLOADS)/adtsos.raw \
	$(PAYLOADS)/SOSLoader.raw \
	$(PAYLOADS)/SK.raw

PREBUILT_PAYLOADS := $(addprefix $(PAYLOADS)/,PD.raw PDSpeed.raw BSpeed.raw SD.raw EsDOS.dmp EsDOS1.raw EsDOS2.raw)

payloads: $(BUILT_PAYLOADS) $(PREBUILT_PAYLOADS)

$(PAYLOADS)/%: $(PREBUILT)/%
	@mkdir -p $(PAYLOADS)
	cp $< $@

$(OBJ):
	@mkdir -p $(OBJ)

# Version-stamped client messages.
$(CLIENT)/messages.asm: $(CLIENT)/messagesOrig.asm Makefile
	sed 's/%ADTPRO_VERSION%/$(VERSION)/' $< > $@

$(OBJ)/tail.o: $(CLIENT)/tail.asm | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -o $@ tail.asm

CLIENT_SOURCES := $(shell find $(CLIENT) -name '*.asm' -o -name '*.i' -o -name '*.s' -o -name '*.cfg')

# ProDOS serial client
$(OBJ)/sermain.o: $(CLIENT_SOURCES) $(CLIENT)/messages.asm | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -I . -o $@ prodos/serial/sermain.asm
$(OBJ)/ADTPRO.BIN: $(OBJ)/sermain.o $(OBJ)/tail.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/serial/adtpro.cfg $^

# ProDOS audio client
$(OBJ)/audmain.o: $(CLIENT_SOURCES) $(CLIENT)/messages.asm | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -I . -o $@ prodos/audio/audmain.asm
$(OBJ)/ADTPROAUD.BIN: $(OBJ)/audmain.o $(OBJ)/tail.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/audio/adtpro.cfg $^

# ProDOS Ethernet client
$(OBJ)/ethmain.o: $(CLIENT_SOURCES) $(CLIENT)/messages.asm | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -I . -o $@ prodos/ethernet/ethmain.asm
$(OBJ)/ADTPROETH.BIN: $(OBJ)/ethmain.o $(OBJ)/tail.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/ethernet/adtpro.cfg $(OBJ)/ethmain.o $(IP65LIB) $(OBJ)/tail.o

# ProDOS launchers (disk images only)
$(OBJ)/launch.o: $(CLIENT_SOURCES) | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -I . -o $@ prodos/launch.asm
$(OBJ)/startup.o: $(CLIENT_SOURCES) | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -I . -o $@ prodos/startup.asm
$(OBJ)/ADTPRO: $(OBJ)/launch.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/adtprolaunch.cfg $^
$(OBJ)/STARTUP.SYSTEM: $(OBJ)/startup.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/adtprolaunch.cfg $^

# Speediboot grubs
$(OBJ)/grub2.o: $(CLIENT_SOURCES) | $(OBJ)
	cd $(CLIENT)/prodos/serial/grub2 && $(CA65) -t none -o $@ grub2.asm
$(OBJ)/GRUB2: $(OBJ)/grub2.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/serial/grub2/grub2.cfg $^
$(OBJ)/grub_vsdrive.o: $(CLIENT_SOURCES) | $(OBJ)
	cd $(CLIENT)/prodos/serial/grub2 && $(CA65) -t none -o $@ grub_vsdrive.asm
$(OBJ)/GRUB_VSDRIVE: $(OBJ)/grub_vsdrive.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/serial/grub2/grub_vsdrive.cfg $^

# DOS ADT
$(OBJ)/ADT: $(CLIENT_SOURCES) | $(OBJ)
	cd $(CLIENT)/dos && $(CL65) -t none -o $@ adt.s && rm -f adt.o

# Virtual serial drive (ProDOS)
$(OBJ)/vsdrive_low.o $(OBJ)/vsdrive_high.o $(OBJ)/vsdrive_speed.o: $(OBJ)/%.o: $(CLIENT_SOURCES) | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -I . -o $@ prodos/serial/drive/$*.asm
$(OBJ)/VSDRIVE_LOW: $(OBJ)/vsdrive_low.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/serial/drive/vsdrive_low.cfg $^
$(OBJ)/VSDRIVE_HIGH: $(OBJ)/vsdrive_high.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/serial/drive/vsdrive_high.cfg $^
$(OBJ)/VSDRIVE_SPEED: $(OBJ)/vsdrive_speed.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/serial/drive/vsdrive_high.cfg $^

# Virtual Ethernet drive (ProDOS)
$(OBJ)/vedrive_low.o: $(CLIENT_SOURCES) | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -I . -o $@ prodos/ethernet/drive/vedrive_low.asm
$(OBJ)/vedrive_high.o: $(CLIENT_SOURCES) | $(OBJ)
	cd $(CLIENT) && $(CA65) -t apple2 -I . -o $@ prodos/ethernet/drive/vedrive_high.asm
$(OBJ)/VEDRIVE_LOW: $(OBJ)/vedrive_low.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/ethernet/drive/vedrive_low.cfg $^ $(IP65LIB)
$(OBJ)/VEDRIVE_HIGH: $(OBJ)/vedrive_high.o
	cd $(CLIENT) && $(LD65) -o $@ -C prodos/ethernet/drive/vedrive_high.cfg $^ $(IP65U2LIB)

# SOS (Apple ///) serial client, loader and kernel
$(OBJ)/sossermain.o: $(CLIENT_SOURCES) $(CLIENT)/messages.asm | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -I . -o $@ sos/serial/sermain.asm
$(OBJ)/ADTSOS: $(OBJ)/sossermain.o $(OBJ)/tail.o
	cd $(CLIENT) && $(LD65) -o $@ -C sos/serial/adtpro.cfg $^
$(OBJ)/sosethmain.o: $(CLIENT_SOURCES) $(CLIENT)/messages.asm | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -I . -o $@ sos/ethernet/ethmain.asm
$(OBJ)/ADTSOSETH: $(OBJ)/sosethmain.o $(OBJ)/tail.o
	cd $(CLIENT) && $(LD65) -o $@ -C sos/ethernet/adtpro.cfg $(OBJ)/sosethmain.o $(IP65LIB) $(OBJ)/tail.o
$(OBJ)/loader.o: $(CLIENT_SOURCES) | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -I . -o $@ sos/serial/loader.asm
$(OBJ)/LOADER: $(OBJ)/loader.o
	cd $(CLIENT) && $(LD65) -o $@ -C sos/serial/loader.cfg $^
$(OBJ)/kernel.o: $(CLIENT_SOURCES) | $(OBJ)
	cd $(CLIENT) && $(CA65) -t none -o $@ sos/serial/kernel.asm
$(OBJ)/SK: $(OBJ)/kernel.o
	cd $(CLIENT) && $(LD65) -o $@ -C sos/serial/kernel.cfg $^

$(PAYLOADS)/adtpro.raw: $(OBJ)/ADTPRO.BIN ; @mkdir -p $(PAYLOADS) && cp $< $@
$(PAYLOADS)/adtproaud.raw: $(OBJ)/ADTPROAUD.BIN ; @mkdir -p $(PAYLOADS) && cp $< $@
$(PAYLOADS)/adtproeth.raw: $(OBJ)/ADTPROETH.BIN ; @mkdir -p $(PAYLOADS) && cp $< $@
$(PAYLOADS)/grub2.bin: $(OBJ)/GRUB2 ; @mkdir -p $(PAYLOADS) && cp $< $@
$(PAYLOADS)/grub_vsdrive.bin: $(OBJ)/GRUB_VSDRIVE ; @mkdir -p $(PAYLOADS) && cp $< $@
$(PAYLOADS)/adt.raw: $(OBJ)/ADT ; @mkdir -p $(PAYLOADS) && cp $< $@
$(PAYLOADS)/vsdrive_speed.raw: $(OBJ)/VSDRIVE_SPEED ; @mkdir -p $(PAYLOADS) && cp $< $@
$(PAYLOADS)/adtsos.raw: $(OBJ)/ADTSOS ; @mkdir -p $(PAYLOADS) && cp $< $@
$(PAYLOADS)/SOSLoader.raw: $(OBJ)/LOADER ; @mkdir -p $(PAYLOADS) && cp $< $@
$(PAYLOADS)/SK.raw: $(OBJ)/SK ; @mkdir -p $(PAYLOADS) && cp $< $@

# ---------------------------------------------------------------------------
# Distribution disk images, built with the adtpro CLI's disk tools
# ---------------------------------------------------------------------------

PRODOS_DISK  := $(DISKS)/ADTPRO-$(VERSION)
VDRIVE_DISK  := $(DISKS)/VDRIVE-$(VERSION).DSK
SOS_DISK     := $(DISKS)/ADTPROSOS-$(VERSION).DSK
VOLNAME      := ADTPRO.$(VERSION)
VDRIVEVOL    := VDRIVE.$(VERSION)
SOSVOLNAME   := ADTPROSOS.$(VERSION)

$(ADTPRO_CLI): $(shell find Sources -name '*.swift')
	$(SWIFT) build -c release --product adtpro

disks: $(ADTPRO_CLI) $(OBJ)/ADTPRO.BIN $(OBJ)/ADTPROAUD.BIN $(OBJ)/ADTPROETH.BIN $(OBJ)/ADTPRO $(OBJ)/STARTUP.SYSTEM \
       $(OBJ)/VSDRIVE_LOW $(OBJ)/VSDRIVE_HIGH $(OBJ)/VEDRIVE_LOW $(OBJ)/VEDRIVE_HIGH $(OBJ)/ADTSOS $(OBJ)/ADTSOSETH
	@mkdir -p $(DISKS)
	@for ext in DSK PO; do \
	  img=$(PRODOS_DISK).$$ext; \
	  base=$(BASEIMAGES)/ADTProBase.$$(echo $$ext | tr A-Z a-z); \
	  cp $$base $$img && \
	  $(ADTPRO_CLI) disk rename $$img $(VOLNAME) && \
	  $(ADTPRO_CLI) disk put $$img $(OBJ)/STARTUP.SYSTEM --name STARTUP.SYSTEM --type SYS --aux 0x2000 && \
	  $(ADTPRO_CLI) disk put $$img $(OBJ)/ADTPRO --name ADTPRO --type SYS --aux 0x2000 && \
	  $(ADTPRO_CLI) disk put $$img $(OBJ)/ADTPRO --name ADTPROAUD --type SYS --aux 0x2000 && \
	  $(ADTPRO_CLI) disk put $$img $(OBJ)/ADTPRO --name ADTPROETH --type SYS --aux 0x2000 && \
	  $(ADTPRO_CLI) disk put $$img $(OBJ)/ADTPRO.BIN --name ADTPRO.BIN --type BIN --aux 0x0800 && \
	  $(ADTPRO_CLI) disk put $$img $(OBJ)/ADTPROAUD.BIN --name ADTPROAUD.BIN --type BIN --aux 0x0800 && \
	  $(ADTPRO_CLI) disk put $$img $(OBJ)/ADTPROETH.BIN --name ADTPROETH.BIN --type BIN --aux 0x0800 || exit 1; \
	done
	cp $(BASEIMAGES)/VDriveBase.dsk $(VDRIVE_DISK)
	$(ADTPRO_CLI) disk rename $(VDRIVE_DISK) $(VDRIVEVOL)
	$(ADTPRO_CLI) disk put $(VDRIVE_DISK) $(OBJ)/VSDRIVE_LOW --name VSDRIVE.LOW --type SYS --aux 0x2000
	$(ADTPRO_CLI) disk put $(VDRIVE_DISK) $(OBJ)/VSDRIVE_HIGH --name VSDRIVE --type SYS --aux 0x2000
	$(ADTPRO_CLI) disk put $(VDRIVE_DISK) $(OBJ)/VEDRIVE_LOW --name VEDRIVE.LOW --type SYS --aux 0x2000
	$(ADTPRO_CLI) disk put $(VDRIVE_DISK) $(OBJ)/VEDRIVE_HIGH --name VEDRIVE --type BIN --aux 0x2000
	$(ADTPRO_CLI) disk put $(VDRIVE_DISK) $(CLIENTLIB)/cc65/loader.system --name VEDRIVE.SYSTEM --type SYS --aux 0x2000
	$(ADTPRO_CLI) disk get $(BASEIMAGES)/SysUtilsA3-VSDrive-1.31.dsk VSDRIVE.A3DRVR $(OBJ)/VSDRIVE.A3DRVR
	$(ADTPRO_CLI) disk put $(VDRIVE_DISK) $(OBJ)/VSDRIVE.A3DRVR --name VSDRIVE.A3DRVR --type PCD
	cp $(BASEIMAGES)/ADTProSOSBase.dsk $(SOS_DISK)
	$(ADTPRO_CLI) disk rename $(SOS_DISK) $(SOSVOLNAME)
	$(ADTPRO_CLI) disk put $(SOS_DISK) $(OBJ)/ADTSOS --name SOS.INTERP --type SOS --aux 0x0000
	$(ADTPRO_CLI) disk put $(SOS_DISK) $(OBJ)/ADTSOSETH --name SOS.INTERPETH --type SOS --aux 0x0000
	$(ADTPRO_CLI) disk create $(DISKS)/Virtual.po --name Hosted.VDrive1 --blocks 1600
	$(ADTPRO_CLI) disk create $(DISKS)/Virtual2.po --name Hosted.VDrive2 --blocks 1600
	@ls -l $(DISKS)

# ---------------------------------------------------------------------------
# macOS app
# ---------------------------------------------------------------------------

app:
	xcodegen generate
	xcodebuild -project ADTPro.xcodeproj -scheme ADTPro -configuration Release -derivedDataPath .build/xcode build

# ---------------------------------------------------------------------------
# Linux
# ---------------------------------------------------------------------------

linux-test:
	docker run --rm -v $(ROOT):/src:ro swift:6.1 bash -c "cp -r /src /work && cd /work && rm -rf .build && swift build && swift test"

clean:
	rm -rf $(OBJ) $(DISKS) $(CLIENT)/messages.asm
	$(SWIFT) package clean
