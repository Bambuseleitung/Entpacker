# Entpacker

iPhone-App im Stil von „Unzip“: Dateien verwalten, Archive entpacken, Videos/Audio in praktisch jedem Format abspielen (VLC-Engine).

- Archiv-Inhalt ansehen (Tipp auf ein Archiv) und einzelne Dateien direkt daraus öffnen (Video im Player, Rest in der Vorschau), ohne alles zu entpacken
- Passwörter werden pro Archiv für die Sitzung gemerkt
- Archive: ZIP, CBZ, 7z, RAR, CBR, TAR, GZ, TGZ, BZ2, TBZ2, XZ, TXZ, LZMA
- Passwörter: ZIP (ZipCrypto und AES), 7z (auch verschlüsselte Dateilisten), RAR. Die App fragt nach, wenn das Entpacken ohne Passwort scheitert.
- Große Archive: ZIP, 7z und RAR werden von der Platte auf die Platte gestreamt (kein Laden in den Speicher). TAR/GZ/BZ2/XZ/LZMA liegen im Speicher, sehr große Dateien dieser Formate können das iPhone überfordern.
- Video/Audio: alles, was VLC kann (MKV, AVI, WMV, FLV, WebM, TS, VOB, RMVB, FLAC, OGG, APE …), mit Ton- und Untertitelwahl, auch im Hintergrund
- Alles andere (PDF, Bilder, Office, Text …): Quick Look; was Quick Look nicht kennt, probiert der Player
- Dateien holen: „+“, „Öffnen mit“ aus anderen Apps, oder in der Dateien-App unter „Auf meinem iPhone → Entpacker“

Bau: GitHub → Actions → „Entpacker (IPA)“ → Run workflow, dann die IPA mit Sideloadly installieren.
