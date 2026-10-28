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
3. Sul telefono scrivi il **codice di 4 cifre** e tocca *Connetti al Mac*; scegli
   «Telecomando Slide XXXX» dall'elenco (XXXX è il codice breve del tuo Mac, scritto nel menu).
   Dopo il primo collegamento il telefono si riconnette da solo, senza codice.
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
- Se riordini, aggiungi o togli slide mentre sei collegato, le note si rileggono da sole.
- Il salto a una slide avanza/arretra a piccoli passi (PowerPoint per Mac non accetta il salto
  diretto da AppleScript): con molte animazioni intermedie può richiedere un istante.
  Le slide nascoste non si possono scegliere: in presentazione PowerPoint le salta.
- *Genera un nuovo codice* (menu del Mac) scollega i telefoni e annulla le riconnessioni salvate.
  Se un telefono vicino sbaglia il codice molte volte, l'app ne genera uno nuovo da sola (i telefoni
  già collegati restano collegati) e lo segnala nel menu.
- *Collegamento cifrato* (menu del Mac): il Bluetooth richiede l'abbinamento di sistema e cifra
  comandi e note. La prima volta Mac e telefono chiedono di confermare l'abbinamento. Consigliato con
  presentazioni riservate; se l'abbinamento non riesce, togli la spunta.

## Note per l'IT / sicurezza

Pensata per non assomigliare in nulla a un malware e per essere verificabile:

| | |
|---|---|
| Codice | Swift nativo arm64, compilato in locale da questo sorgente (`mac/build.sh`). Nessun processo figlio, nessun interprete esterno, nessun download. |
| AppleScript | Un solo script, **incorporato nel sorgente** (`mac/Sources/PowerPointScript.swift`) ed eseguito dentro l'app con `NSAppleScript`: non si scarica né si modifica, e non c'è `osascript`. |
| Firma | Ad-hoc con **runtime rinforzato** (`codesign --options runtime`), senza Team ID (nessun account sviluppatore Apple). Unico entitlement: `com.apple.security.automation.apple-events`. |
| Rete | **Nessuna.** Niente socket, server, connessioni Internet. Solo Bluetooth LE (servizio GATT dedicato). |
| Automazione | Apple Events **solo a Microsoft PowerPoint** (avanti/indietro/avvio/fine/schermo nero, lettura di titoli e note). Compare in Privacy › Automazione. Niente System Events, niente simulazione di tastiera, niente Accessibilità. |
| File | Non legge né scrive file. Nelle preferenze (`UserDefaults`) salva solo codice di accoppiamento, token di riconnessione e opzioni. |
| Avvio | Solo manuale. Nessun LaunchAgent, nessun elemento di login, nessuna persistenza. |
| Bluetooth | Comandi accettati solo dopo il codice a 4 cifre (o un token di riconnessione da 128 bit). Blocchi crescenti dopo 5 errori, codice nuovo automatico dopo 20. Testo dei comandi validato su un elenco chiuso. Cifratura opzionale tramite abbinamento di sistema. |
| Pagina telefono | Statica (HTML/JS/CSS), nessun server, nessun dato inviato in rete. Le note viaggiano solo via Bluetooth tra telefono e Mac. Pubblicazione con azioni GitHub fissate a commit precisi. |

Ogni ricompilazione cambia l'impronta della firma ad-hoc: macOS può richiedere di nuovo i permessi
Bluetooth e Automazione (se PowerPoint risponde «permesso negato»:
`tccutil reset AppleEvents com.azini.telecomandoslide`, poi riapri l'app).

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

Protocollo: il telefono scrive comandi testuali brevi (`hello:1234`, `resume:<token>`, `next`, `prev`, `first`,
`goto:N`, `start`, `stop`, `black`, `reload`); il Mac risponde con messaggi JSON
(`state`, `deck`, `auth`, `err`) divisi in frame `[id u8][indice u16][totale u16][dati]`.
La pagina si pubblica da sola su GitHub Pages a ogni push su `main` (`.github/workflows/pages.yml`).
Modalità demo senza Mac: <https://azini-oss.github.io/telecomando-slide/?demo>
