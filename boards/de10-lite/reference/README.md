# DE10-Lite reference documents

Vendor documents this board's files were written from. They are copyrighted by
their publishers, so they aren't in the repo (`.gitignore`: `boards/*/reference/*.pdf`);
download them into this folder.

## DE10-Lite User Manual (Terasic)

- **Official source:** terasic.com.tw → DE10-Lite → Resources → *DE10-Lite User Manual*.
- **Edition used:** 24 January 2017, 74 pages. A copy of it (as `DE10info.pdf`):
  <https://faculty-web.msoe.edu/meier/ce1901/datasheets/DE10info.pdf>
  - SHA-256 `dba033faee6bdae1aea178075b448af11580cf3713ea24384f071fb080e22f9b`.
    Check it with `sha256sum`: a different hash means a different edition.
- **Save as:** `DE10-Lite_User_Manual.pdf`

Used for:

| file | from |
|---|---|
| `pins.tcl` | the pin tables in chapter 3 (clock, keys, switches, LEDs, 7-segment displays); §3.5, Figure 3-18 and Table 3-7 for the GPIO header (JP1) |
| `pins.tcl` (IO_STANDARD) | the same tables: every bank on this board is 3.3-V LVTTL |
