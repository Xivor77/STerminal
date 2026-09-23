# STerminal

Ripristino di sessioni e **aree di lavoro** per PowerShell su Windows Terminal.

Risolve il fastidio di partenza: a ogni riavvio i tab tornano vergini. STerminal lavora su due livelli.

## Due livelli

1. **Ripristino nativo di Windows Terminal** (la "fotografia").
   Dalla 1.21 WT sa gia' ricaricare il contenuto dei tab dell'ultima sessione (testo, coi colori). STerminal lo da' per acceso (`firstWindowPreference: persistedWindowLayout`) e aggiunge al profilo PowerShell il report della cartella corrente, cosi' i tab tornano anche nella dir giusta. Copre il caso "riavvio il PC, rivoglio quello che avevo".

2. **Aree di lavoro** (quello che WT *non* fa).
   Gruppi di tab **nominati e selezionabili**, ognuno con la sua cartella e, volendo, un **comando da rilanciare** all'apertura. Li definisci, li salvi, li riprendi quando vuoi — da una mini-interfaccia o a comandi. E' la cosa che a WT manca (feature request #8590, ancora aperta), in stile "aree di lavoro" di Edge.

## Requisiti
- Windows 10/11 con **Windows Terminal 1.21+** — **qualunque canale**: Stabile, Preview o Canary (vedi *Il canale di cattura*)
- **Windows PowerShell 5.1** o **PowerShell 7** (entrambe supportate)

## Componenti
- `STerminal.psm1` — il modulo (motore).
- `Show-STerminal.ps1` — la mini-interfaccia (WPF).
- `tests\STerminal.Tests.ps1` — la suite di test.

## Installazione
Il profilo PowerShell 5.1 e' configurato per:
- riportare la cartella corrente a WT (ripristino dir);
- auto-registrare ogni tab WT interattivo (serve a salvare i tab nelle aree).

A comandi: `Import-Module <cartella-del-clone>\STerminal.psm1`
Interfaccia: lancia `Show-STerminal.ps1`, o la scorciatoia "STerminal" nel menu Start.

## Uso

### Mini-interfaccia (`Show-STerminal.ps1`)
Due colonne:
- **Aree di lavoro** — la lista delle aree salvate: **Riprendi / Elimina / Aggiorna / Modifica...**.
  **Modifica...** apre un dialogo dove si rinomina **l'area** (casella in cima) e **i titoli
  delle schede**, dallo stesso posto, con un solo *Applica*. Attenzione: area + titoli sono
  **due gesti**, non uno — se uno fallisce, l'altro resta fatto, e l'esito li conta tutti e
  due. E rinominare cambia la riga **salvata**, non il tab che hai sullo schermo: vedi
  *Limiti onesti*.
- **Tab aperti** — tutto cio' che hai aperto adesso (anche i tab occupati: claude, server...), etichettato `path - attivita [pid]`. I tab che **appartengono gia' a un'area** sono colorati **col colore di quell'area** e la riga lo dice (`in: servizi`), cosi' non li riaggiungi per sbaglio; se il riconoscimento e' solo per cartella, la riga lo dichiara (`in: servizi (stessa cartella)` — vedi *Come si riconosce un tab*). Selezioni uno o piu' tab e **Aggiungi a gruppo**: si apre un dialogo dove **scegli l'area da un elenco** (creare e' un gesto separato, «Nuova area»: cosi' un refuso non crea un'area nuova in silenzio) e uno di due modi mutuamente esclusivi:
  - **Automatico** — colori assortiti (distinti) + titoli originali;
  - **Per singola tab** — imposti titolo e colore di ogni tab a mano (menu coi colori).

### A comandi

**Aree:**
- `New-STWorkspace -Name <n> -Tabs @(@{Title;Cwd;Command;Color}...)` — definisce un'area da zero.
- `Save-STWorkspace -Name <n> [-Group <g>]` — cattura i tab aperti registrati (con `-Group`, solo quelli etichettati).
- `Add-STWorkspaceTab -Name <n> -Tabs @(...) [-AutoColor] [-AllowDuplicate]` — aggiunge tab a un'area (la crea se non c'e'); con `-AutoColor` assegna a ogni tab senza colore un colore distinto dalla tavolozza. **E' idempotente**: un tab con la stessa *ricetta* (cartella + shell + comando) di uno gia' presente **non viene riaggiunto**, ne' dall'area ne' dentro lo stesso lotto. Restituisce `{Added, SkippedExact, SkippedRecipe, Total}` — quello che e' successo, non quello che era stato chiesto. Per due tab gemelli voluti: `-AllowDuplicate`.
- `Rename-STWorkspace -Name <n> -NewName <m>` — rinomina l'area (cartella e contenuto). Rifiuta nomi non validi, nomi gia' esistenti (niente fusioni) e nomi uguali al vecchio.
- `Set-STWorkspaceTabTitle -Name <n> -Title <t> -TitleVecchio <v> -Cwd <cartella>` — rinomina una scheda **dentro** un'area. La riga si indirizza con titolo vecchio + cartella (mai per posizione nella lista); due schede identiche in titolo e ricetta non sono indirizzabili e il gesto **rifiuta**.
- `Set-STWorkspaceTerminale -Name <n> -Corrente` — converte l'area al canale di terminale in cui sei **adesso**: va chiamato DA DENTRO quel terminale (vedi *Il canale di cattura*).
- `Set-STWorkspaceColor -Name <n> [-Color '#rrggbb']` — il colore **dell'area**, distinto da quello dei singoli tab (che resta per `wt --tabColor` alla riapertura). Senza `-Color` ne sceglie uno non ancora usato dalle altre aree; un colore che WPF non sa leggere viene rifiutato.
- `Resume-STWorkspace -Name <n> [-TerminaleCorrente]` — riapre l'area: una finestra WT coi suoi tab, pre-colorati, nelle cartelle giuste, ognuno che ristampa il suo storico e poi rilancia il suo comando. `-TerminaleCorrente` e' la deviazione una-tantum dal canale registrato, dichiarata a voce alta.
- `Get-STWorkspace` / `Remove-STWorkspace -Name <n>`.

**Tab:**
- `Set-STerminalTab -Title <t> -Color <#rrggbb> -Command <cmd> -Group <g>` — imposta i metadati del tab corrente.
- `Get-STLiveTab` — elenca i tab shell aperti (cartella + comando rieseguibile), anche occupati.
- `Get-STOpenSlots` — i tab registrati attualmente aperti.

### Esempio: gruppo "servizi" (un servizio per tab)
```powershell
New-STWorkspace -Name "servizi" -Tabs @(
  @{ Title='api';     Cwd='C:\dev\api';     Command="& 'C:\dev\api\run.ps1'" }
  @{ Title='web';     Cwd='C:\dev\web';     Command="npm start" }
  @{ Title='worker';  Cwd='C:\dev\worker';  Command="& 'C:\dev\worker\.venv\Scripts\python.exe' -m worker" }
)
Resume-STWorkspace -Name "servizi"
```

### Esempio: raggruppare per attivita' (anche tab nella stessa cartella)
- **Etichetta:** in ogni tab, `Set-STerminalTab -Group "lavoro"`, poi `Save-STWorkspace -Name "lavoro" -Group "lavoro"`.
- **Oppure dalla UI:** seleziona i tab aperti nella colonna destra e "Aggiungi a gruppo".

## Come si riconosce un tab gia' in un'area

Non esiste un'etichetta che leghi un tab aperto a una voce salvata: il pid cambia a ogni
riavvio, e il titolo lo puoi riscrivere tu. Il riconoscimento avviene per confronto, e ha
**due gradi, entrambi dichiarati nella riga**:

| grado | come | in lista |
|---|---|---|
| **ricetta** | cartella + shell + comando, normalizzati | `in: servizi` |
| **cartella** | solo la cartella coincide | `in: servizi (stessa cartella)` |

Il secondo esiste perche' un'area salvata mesi fa puo' avere i comandi scritti in un modo
e i processi vivi in un altro — per esempio con gli argomenti fra apici — o perche' il
processo vero non e' quello salvato (un `.bat` gira dentro `cmd.exe`). Senza il ripiego,
di sei tab di un'area se ne riconoscerebbe uno.

**Limiti da conoscere:** il grado «cartella» e' largo — due tab aperti nella stessa
cartella risultano entrambi «gia' li'». E' voluto: per non riaggiungere un doppione, un
avviso in piu' costa meno di un riconoscimento mancato. Le virgolette negli argomenti
**non** vengono normalizzate, di proposito: fondere due comandi che non sono lo stesso
sarebbe peggio. Un'identita' certa richiederebbe un identificatore stabile scritto
nell'area e riportato al ripristino: non c'e' ancora.

## Il canale di cattura (Stabile / Preview / Canary)

`wt.exe` e' un **alias di esecuzione**: Stabile, Preview e Canary dichiarano tutti lo stesso
alias e Windows ne tiene attivo uno alla volta. Lanciare `wt.exe` e basta, quindi, non dice
*in quale* canale si riaprira' un'area.

La regola di STerminal: **l'area segue il terminale in cui e' stata catturata**. Ogni tab
registra alla nascita il terminale che lo ospita (il processo padre della shell, osservato —
mai dedotto dal nome del pacchetto) e l'area lo conserva in un file suo (`terminale.json`,
accanto a `workspace.json`). Al *Riprendi* l'area si riapre **nello stesso canale**; se quel
terminale non esiste piu' (area copiata da un'altra macchina, canale disinstallato) si
ripiega sull'alias `wt.exe` **e lo si dice a voce alta**, come per ogni ripiego.

Per **cambiare** il canale di un'area serve un gesto esplicito:

```powershell
Set-STWorkspaceTerminale -Name <area> -Corrente
```

⚠️ **Va chiamato DA DENTRO il terminale che si vuole registrare**: il comando registra il
padre della shell in cui gira, qualunque esso sia. Chiamato dal terminale sbagliato,
registra quello sbagliato.

## Come funziona (in breve)
Ogni tab si registra (uno "slot" in `~/.sterminal`) e cattura il proprio output con `Start-Transcript`. Un'area = un set di tab in `~/.sterminal/workspaces/<nome>`. Il Resume ricrea i tab con l'eseguibile del canale registrato (ripiego dichiarato su `wt.exe`), **gia' colorati e titolati alla nascita** (cosi' scavalca il bug WT #19970 del focus-jump) e nelle cartelle giuste; il comando passa in base64 (`-EncodedCommand`) per non farsi rompere il quoting da `wt`. Per la lista dei tab aperti, `Get-STLiveTab` scandisce l'albero dei processi e legge la cartella corrente di ciascuno dal PEB — cosi' vede anche i tab occupati o non registrati.

## Limiti onesti
- **Rinominare cambia la riga SALVATA, non il tab vivo.** Dal dialogo *Modifica* (o con
  `Rename-STWorkspace` / `Set-STWorkspaceTabTitle`) sullo schermo non succede niente: i nomi
  nuovi entrano in scena al prossimo *Riprendi*. Se sembra che non sia successo niente, e'
  andata bene.
- **Niente punti nei nomi delle aree.** Un punto fa sembrare il nome un file, e il nome di
  un'area diventa una cartella: `v1.2` viene rifiutato, con il motivo detto. Vale anche per
  spazi finali, caratteri non validi per una cartella e nomi riservati di Windows (CON, NUL...).
- **Due schede identiche in titolo e ricetta non si possono rinominare**: non sono
  indirizzabili e il gesto **rifiuta** invece di colpirne una a caso. Una coppia gemella
  *voluta* si crea con `-AllowDuplicate`, ma resta non rinominabile finche' e' identica.
- **Area + titoli nello stesso *Applica* sono due gesti**, senza rollback di sequenza: se la
  rinomina dell'area fallisce i titoli vanno comunque (col nome vecchio), e viceversa.
  L'esito li conta tutti e due: un "fatto" che ne nasconde meta' sarebbe peggio.
- **Storico = testo.** Lo scrollback torna come testo; i colori ANSI *dentro* l'output vecchio si perdono (`Start-Transcript` li scarta). Colori e nomi *dei tab* invece tornano.
- **Niente stato vivo.** Variabili, job, processi non sopravvivono: l'area e' fotografia + struttura + comando, non una sessione viva. Il "motore vivo" e' una fase futura.
- **Niente identificativo di finestra.** WT usa un processo unico per tutte le finestre e `WT_SESSION` e' per-tab: la shell non sa in quale finestra sta. Per questo si raggruppa **per etichetta/selezione**, non "per finestra".
- **Titolo/colore dei tab:** la shell non puo' leggere quelli impostati dalla UI di WT (click destro / doppio click). Usali via `Set-STerminalTab` o l'interfaccia.
- **`claude --resume` catturato e' "secco":** piu' tab claude nella stessa cartella, riaperti, collassano sull'ultima sessione. Per separarli serve l'ID sessione (`claude --resume <id>`).
- **Resume di un'area di servizi li *riavvia*** (conflitti se gia' in esecuzione).
- **Il riconoscimento «stessa cartella» e' un'approssimazione**, non un'identita': vedi *Come si riconosce un tab gia' in un'area*.
- **Non testati:** percorsi di rete (UNC) e path oltre 260 caratteri.

## Test
`powershell.exe -NoProfile -File tests\STerminal.Tests.ps1`
Copre: estrazione storico, salvataggio, percorsi/titoli difficili (spazi, apostrofi, accenti, cartelle sparite), comando per tab, filtro per gruppo, gli helper dei tab vivi, la deduplicazione e la firma delle ricette, il colore delle aree, il riconoscimento dei tab, la rinomina di aree e schede e la guardia sui nomi. Lancia anche le prove della mini-interfaccia (`Show-STerminal.ps1 -TestAddDialog`), che pilotano davvero i controlli WPF.

⚠️ **Il banco va lanciato con `powershell.exe`, non con `pwsh`.** Le prove registrano tab di
test con shell `powershell.exe` e una guardia confronta il nome del processo vivo con quello
registrato: da PowerShell 7 il processo del banco e' `pwsh.exe`, la guardia fa il suo lavoro
e lo scarta — e tu vedi rossi **falsi**. Il modulo gira sia in 5.1 sia in 7; il banco no.

Il banco **verifica il proprio isolamento** e si rifiuta di partire se non regge: senza quel controllo, un'esecuzione con il modulo caricato sotto un altro nome scriverebbe nelle aree vere.

## Roadmap
- Chat claude distinte nella stessa cartella via `claude --resume <session-id>`.
- Storico a colori (cattura VT).
- **Fase 2 — motore vivo:** mantenere viva la sessione (variabili/job) tra le riaperture, via named pipe (`Enter-PSHostProcess`).
- Nella UI: ricolorare e riordinare i tab di un'area (la rinomina c'e' gia': tasto *Modifica...*).
