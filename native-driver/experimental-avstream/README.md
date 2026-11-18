# Experimental: custom AVStream minidriver (NOT the install path)

Scaffold for a from-scratch `FastTrackDuoNew.sys` (WDM + AVStream + stream gate).

**Do not install this for daily use.** Building requires the WDK
(`WindowsKernelModeDriver10.0`). USB isoch bring-up is incomplete. Shipping a
custom kernel binary also needs EV + WHCP signing.

The **working** replacement for Avid’s buggy `.sys` is:

[`../usbaudio/`](../usbaudio/) — bind Duo to Microsoft **`usbaudio.sys`**.

Duo is USB Audio Class 1.0 (`USB\Class_01&SubClass_01&Prot_00`). Avid’s package
only outranks the inbox class driver; Mac already runs class-compliant.
