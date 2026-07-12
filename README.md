# PrintSpot

**Find & print at public printers anywhere.**

PrintSpot is a native iOS app for printing photos and documents at public
[Princh](https://princh.com)-enabled printers — the kind found in thousands of
libraries and public spaces worldwide. Scan the printer's code (or find one
near you on a map), pick your files, set your options, see the price, and send
the job for release at the printer.

## Features

- **Three ways to pick a printer**
  - 📷 **Scan** the QR/barcode on the printer
  - 📍 **Find a printer** — searchable directory of ~5,000+ public printers
    worldwide, sorted by distance when you allow location
  - ⌨️ **Enter the printer ID** manually (e.g. `108815`)
- **⭐ Saved printers** — favourite the ones you use and load them in one tap
- **Photos & documents** — add from your photo library or the Files app
  (PDF, images, and more; converted to PDF server-side)
- **Print options** — colour / B&W, copies, 2-sided, and paper size, set
  **per file** or **for all files at once** (no more toggling 100 files by hand)
- **💵 Live price estimate** — running total computed from the printer's own
  price list, updating as you change options; exact total confirmed at review
- **Order & release** — creates the order and waits for release at the printer,
  then shows your order code

## How it works

PrintSpot talks directly to the Princh public-printing REST API, reproducing
the flow the official web app uses:

1. `POST /auth/v2/oauth/token` — anonymous public-printing token
2. `GET /rest/v5/devices/{displayId}` — resolve the printer + its capabilities
3. `GET /rest/v5/connectors/{id}` — encryption key id for uploads
4. `POST files.princh.com/v3/files/pdf/` — upload each file (converted to PDF)
5. `POST /rest/v5/documents` — create each document with a print ticket
6. `POST /rest/v5/order-sessions` — bundle the documents into an order
7. `GET /rest/v5/order-sessions/{id}/wait` — wait for release at the printer

The **Find a printer** directory comes from the public
`geo-bridge.princh.com/get-locations` endpoint.

## Project structure

```
PrintSpot/
├─ ContentView.swift              Root view — routes between screens
├─ Printing/
│  ├─ PrinchModels.swift          Codable models for the Princh API
│  ├─ PrinchAPI.swift             Async API client (actor) + code parser
│  ├─ PrintFlowModel.swift        @MainActor flow orchestrator / state
│  ├─ PrinterDirectory.swift      Global printer directory (find-a-printer)
│  └─ SavedPrintersStore.swift    Persisted favourites (UserDefaults)
└─ Views/
   ├─ QRScannerView.swift         AVFoundation QR/barcode scanner
   ├─ PrinterSelectionView.swift  Main page (scan / find / manual / saved)
   ├─ FindPrinterView.swift       Searchable directory + "near me"
   └─ PrintJobView.swift          Configure → review → send → done
```

## Requirements

- Xcode 16+ (uses file-system–synchronized project groups)
- iOS 26.5+ deployment target
- Swift 5

## Building

1. Open `PrintSpot.xcodeproj` in Xcode.
2. Select the **PrintSpot** scheme and a simulator or device.
3. Build & run (⌘R).

The app requests **camera** access (to scan printer codes) and, optionally,
**location** access (to sort printers by distance). Both usage descriptions are
configured in the target's build settings.

## Privacy

PrintSpot has no backend of its own. It communicates only with the Princh
service to print, and uses your location solely on-device to sort nearby
printers. Saved printers are stored locally on your device.

## Disclaimer

This is an independent client for the Princh public-printing service and is not
affiliated with or endorsed by Princh. "Princh" is a trademark of its owner.
