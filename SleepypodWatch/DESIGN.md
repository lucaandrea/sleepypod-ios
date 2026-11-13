---
name: sleepypod Watch
spacing:
  compact: "2pt"
  small: "4pt"
  standard: "8pt"
  detail: "12pt"
components:
  adjustment:
    width: "44pt"
    height: "44pt"
  stop-temperature:
    height: "44pt minimum"
---

## Overview

An extension of the existing native Watch recorder. Use watchOS's own navigation,
buttons, typography and scroll behavior. The app is a compact control surface.

## Colors

Inherit semantic foreground and secondary foreground over the native Watch ground.
Use the system's button states, including disabled controls. Do not add a second
meaning through color alone. Preview text and the example sleeper identify fixtures.

## Typography

System headline for assignment, footnote for secondary context, and semibold title2
with monospaced digits for the requested temperature. Use Dynamic Type text styles.
The temperature row reflows vertically when its contents no longer fit horizontally.

## Layout

A NavigationStack contains the vertically scrollable bed controls. Person and side
lead, followed by temperature and Stop. Readings, next wake, refresh and the existing
research recorder follow. The wake destination uses the same live observable state.
Normal and larger Watch sizes are required checks; test the largest supported text.

## Elevation & Depth

Native button surfaces and navigation only; no decorative shadows or invented glass.

## Shapes

Use native watchOS button shapes. Minimum adjustment dimensions are 44 by 44 points.
The Stop temperature label has at least 44 points of height inside its native button.

## Components

Plus/minus changes the requested temperature by one Fahrenheit degree after a fresh
read. Stop remains available during an in-flight adjustment when its lease is valid.
Next wake includes warming and vibration details; its Stop vibration action expires
with the live account lease. Research recording retains the incumbent controls.

## Do's and Don'ts

- Preserve clear side assignment, explicit expiry and readable Stop controls.
- Do not turn synthetic examples into live hardware claims.
- Do not keep a stale snapshot looking actionable.
- Do not introduce custom gestures, browser controls or decorative charts.
