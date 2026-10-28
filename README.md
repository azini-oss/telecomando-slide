# Telecomando Slide

Telecomando Bluetooth per **PowerPoint sul Mac**: sul telefono hai due pulsanti grandi
(indietro / avanti) e le **note del relatore** ben leggibili, sempre allineate alla slide
mostrata davvero — anche con le animazioni — perché le legge da PowerPoint in tempo reale.

- **App Mac** (`mac/`): piccola app nativa Swift nella barra dei menu. Si annuncia via
  Bluetooth LE, riceve i comandi dal telefono e comanda PowerPoint.
- **Pagina telefono** (`web/`): app web installabile. Si apre da
  <https://azini-oss.github.io/telecomando-slide/>
  - Android: **Chrome** (supporta il Bluetooth web).
  - iPhone: app gratuita **Bluefy** (Safari non supporta il Bluetooth web).

## Uso

1. Sul Mac apri **Telecomando Slide** (`~/Applications`): compare l'icona ▶︎ nella barra dei menu.
   La prima volta macOS chiede il permesso **Bluetooth**: *Consenti*.
2. Dal menu dell'icona: *Mostra QR e codice per il telefono…* → inquadra il QR con il telefono.
3. Sul telefono scrivi il **codice di 4 cifre** e tocca *Connetti al Mac*; scegli «Telecomando Slide»
   dall'elenco. Il codice resta memorizzato sul telefono.
4. Al primo comando macOS chiede se *Telecomando Slide* può controllare **Microsoft PowerPoint**: *OK*.
5. Apri la presentazione in PowerPoint e avviala (dal Mac o dal telefono).

Sul telefono: menu ⋯ per dimensione del testo, elenco slide (tocca per saltare), avvio/fine
presentazione, ricarica note. Il pulsante con lo schermo mette la presentazione in **nero**.
Lo schermo del telefono resta acceso mentre sei collegato.

Comportamento:

- **Avanti** fa esattamente come la freccia → in PowerPoint: prima le animazioni, poi la slide.
- Le note mostrate sono sempre quelle della slide che PowerPoint sta proiettando: se qualcuno
  cambia slide dal Mac, il telefono si aggiorna da solo.
- Se modifichi le note mentre sei collegato: menu ⋯ → *Ricarica le note*.
- Il salto a una slide avanza/arretra passo passo (PowerPoint per Mac non accetta il salto
  diretto da AppleScript): con molte animazioni intermedie può richiedere un istante.
- *Genera un nuovo codice* (menu del Mac) scollega i telefoni: dovranno reinserirlo.

## Note per l'IT / sicurezza

Pensata per non assomigliare in nulla a un malware e per essere verificabile:

| | |
|---|---|
| Codice | Swift nativo arm64, compilato in locale da questo sorgente (`mac/build.sh`). Nessuno script, interprete o processo figlio. |
| Firma | Ad-hoc con **runtime rinforzato** (`codesign --options runtime`). Unico entitlement: `com.apple.security.automation.apple-events`. |
| Rete | **Nessuna.** Niente socket, server, connessioni Internet. Solo Bluetooth LE (servizio GATT dedicato). |
| Automazione | Apple Events **solo a Microsoft PowerPoint** (avanti/indietro/avvio/fine/schermo nero, lettura di titoli e note). Niente System Events, niente simulazione di tastiera, niente Accessibilità. |
| File | Non legge né scrive file. Salva solo il codice di accoppiamento nelle preferenze (`UserDefaults`). |
| Avvio | Solo manuale. Nessun LaunchAgent, nessun elemento di login, nessuna persistenza. |
| Bluetooth | Accetta comandi solo dopo il codice a 4 cifre; dopo 5 errori si blocca per 60 s. Testo dei comandi validato su un elenco chiuso. |
| Pagina telefono | Statica (HTML/JS/CSS), nessun server, nessun dato inviato in rete. Le note viaggiano solo via Bluetooth tra telefono e Mac. |

Verifica della firma:

```bash
codesign -dvv --entitlements - "$HOME/Applications/Telecomando Slide.app"
```

## Sviluppo

```bash
npm test                 # test JS (protocollo e frame Bluetooth)
./mac/run_tests.sh       # test Swift (stessi vettori in shared/)
./mac/build.sh           # test + compila + firma + installa in ~/Applications
```

Verifica del collegamento con PowerPoint senza Bluetooth (agisce sulla presentazione **attiva**):

```bash
"$HOME/Applications/Telecomando Slide.app/Contents/MacOS/TelecomandoSlide" --selftest
```

`--selftest-nav` in più avvia la presentazione attiva e prova avanti/indietro/salto/nero: usalo
solo con una presentazione di prova in primo piano.

Protocollo: il telefono scrive comandi testuali brevi (`hello:1234`, `next`, `prev`, `first`,
`goto:N`, `start`, `stop`, `black`, `reload`); il Mac risponde con messaggi JSON
(`state`, `deck`, `auth`, `err`) divisi in frame `[id u8][indice u16][totale u16][dati]`.
La pagina si pubblica da sola su GitHub Pages a ogni push su `main` (`.github/workflows/pages.yml`).
Modalità demo senza Mac: <https://azini-oss.github.io/telecomando-slide/?demo>
