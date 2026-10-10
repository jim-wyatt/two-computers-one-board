<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT

Appended to every page by pymdownx.snippets (see mkdocs.yml). Any of these
acronyms appearing anywhere in the site gets a dotted underline and a hover
definition, without the author having to mark it up.

Keep the definitions to one line. If a term needs a paragraph it belongs in
docs/glossary.md, and most of these are in both.

This file is NOT in the nav and renders as nothing on its own.
-->
*[ABL]: Application Bootloader — the Qualcomm boot stage that loads the OS
*[API]: Application Programming Interface — the set of calls one piece of software offers another
*[CDC]: Communications Device Class — the USB standard for serial ports and network adapters
*[CI]: Continuous Integration — checks that run automatically on every push
*[COBS]: Consistent Overhead Byte Stuffing — a framing scheme with a bounded worst case
*[CRC]: Cyclic Redundancy Check — a checksum designed to catch transmission errors
*[DHCP]: Dynamic Host Configuration Protocol — how a machine is handed an IP address
*[DT]: Devicetree — a description of what hardware exists and how it is wired
*[FAT32]: A filesystem every operating system can read, which is why the USB drive uses it
*[FOTA]: Firmware Over The Air — updating a device's firmware over a data link instead of a debug probe
*[GPIO]: General Purpose Input/Output — a pin software can read or drive high or low
*[HTTP]: HyperText Transfer Protocol — how a browser fetches a page
*[ICS]: Internet Connection Sharing — Windows' way of sharing a connection with an attached device
*[ISR]: Interrupt Service Routine — code the hardware runs immediately, interrupting whatever was running
*[I2C]: Inter-Integrated Circuit — a two-wire bus for talking to nearby chips
*[MBR]: Master Boot Record — the partition table Windows expects on removable media
*[MCU]: Microcontroller Unit — the small chip: one core, no OS underneath you, exact timing
*[MMU]: Memory Management Unit — the hardware that gives each process its own view of memory
*[MPU]: Microprocessor Unit — the big chip: several cores, an operating system, no timing guarantees
*[NCM]: Network Control Model — the modern USB standard for pretending to be a network adapter
*[NRST]: The hardware reset line on the microcontroller
*[NVS]: Non-Volatile Storage — Zephyr's key/value store in flash, which survives power loss
*[PBL]: Primary Boot Loader — the first code a Qualcomm chip runs, burned into silicon
*[RNDIS]: Remote NDIS — Microsoft's older USB networking protocol, kept for Windows compatibility
*[ROM]: Read-Only Memory — storage fixed at manufacture and unchangeable afterwards
*[RPC]: Remote Procedure Call — calling a function that runs on another machine or chip
*[RTOS]: Real-Time Operating System — one that can guarantee when something happens, not just that it does
*[SBL]: Secondary Boot Loader — the boot stage after the mask ROM
*[SMP]: Simple Management Protocol — the protocol MCUboot and mcumgr speak for firmware updates
*[SoC]: System on Chip — processor, memory controller and peripherals on one piece of silicon
*[SPDX]: Software Package Data Exchange — the standard one-line licence identifier at the top of each file
*[SPI]: Serial Peripheral Interface — a fast four-wire bus for talking to nearby chips
*[SVD]: System View Description — a machine-readable map of a chip's registers, used by debuggers
*[SWD]: Serial Wire Debug — Arm's two-wire interface for flashing and debugging a chip
*[TZ]: TrustZone — the isolated secure world on an Arm processor
*[UART]: Universal Asynchronous Receiver/Transmitter — the hardware behind a plain serial line
*[UDC]: USB Device Controller — the hardware that lets a board be a USB device rather than a host
*[UEFI]: Unified Extensible Firmware Interface — the standard firmware interface a modern OS boots through
*[USB]: Universal Serial Bus
*[XBL]: eXtensible Boot Loader — the Qualcomm stage that configures the memory controller
