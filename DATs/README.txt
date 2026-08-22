LOCAL PRESERVATION DAT LIBRARY
==============================

This folder is populated by UPDATE DATS.bat.

START WEBSITE.bat and BUILD CACHE ONLY.bat read preservation data only from
this folder. They never download DAT files from Redump, GitHub, jsDelivr, etc.

Run UPDATE DATS.bat whenever you want to refresh the preservation sources.
Previously downloaded files are kept if an individual source update fails.
