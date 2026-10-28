/// Script AppleScript incorporato ed eseguito dentro l'app (NSAppleScript): parla solo con PowerPoint,
/// nessun processo esterno, nessun accesso a System Events o alla tastiera.
/// Ogni handler è breve: le operazioni lunghe (note, salto) sono spezzate e richiamate dall'app a passi.
/// Attenzione ai nomi: `out`, `before`, `st` sono parole riservate (PowerPoint o AppleScript).
enum PowerPointScript {
    static let source = """
    -- Errori propri: 1001 non avviata, 1002 slide inesistente, 1003 nessuna presentazione,
    -- 1004 PowerPoint chiuso, 1005 slide nascosta, 1006 fine presentazione, 1007 salto non riuscito,
    -- 1008 già avviata, 1009 slide prima di quella di partenza.

    on ensurerunning()
    	if not (application id "com.microsoft.Powerpoint" is running) then error "PowerPoint chiuso" number 1004
    end ensurerunning

    -- Nei try che ignorano errori "attesi", i problemi gravi (timeout, permessi, app chiusa) vanno rilanciati.
    on rethrowfatal(msg, n)
    	if n is in {-1712, -609, -600, -1743, -10004, 1004} then error msg number n
    end rethrowfatal

    on showview()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			if (count of slide show windows) = 0 then error "Presentazione non avviata" number 1001
    			return slideshow view of slide show window 1
    		end timeout
    	end tell
    end showview

    on deckkey(p)
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			return (full name of p) & "#" & (count of slides of p)
    		end timeout
    	end tell
    end deckkey

    on currentpresentation()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			if (count of slide show windows) > 0 then return presentation of slide show window 1
    			if (count of presentations) > 0 then return active presentation
    			return missing value
    		end timeout
    	end tell
    end currentpresentation

    on readstate()
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 2 seconds
    			if (count of slide show windows) > 0 then
    				set w to slide show window 1
    				set p to presentation of w
    				set v to slideshow view of w
    				set idx to 0
    				set sid to 0
    				set isBlack to false
    				set el to 0
    				try
    					set s to slide of v
    					set idx to slide index of s
    					set sid to slide ID of s
    				on error msg number n
    					my rethrowfatal(msg, n)
    					set idx to 0
    					set sid to 0
    				end try
    				try
    					set isBlack to ((slide state of v) is slide show state black screen)
    				on error msg number n
    					my rethrowfatal(msg, n)
    				end try
    				try
    					set el to presentation elapsed time of v
    				on error msg number n
    					my rethrowfatal(msg, n)
    				end try
    				return {true, idx, count of slides of p, isBlack, el, my deckkey(p), sid}
    			end if
    			set p to my currentpresentation()
    			if p is missing value then return {false, 0, 0, false, 0, "", 0}
    			return {false, 0, count of slides of p, false, 0, my deckkey(p), 0}
    		end timeout
    	end tell
    end readstate

    on titleof(s)
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			repeat with j from 1 to (count of shapes of s)
    				try
    					set sh to shape j of s
    					set t to placeholder type of place holder format of sh
    					if t is placeholder type title placeholder or t is placeholder type center title placeholder or t is placeholder type vertical title placeholder then
    						return content of text range of text frame of sh
    					end if
    				on error msg number n
    					my rethrowfatal(msg, n)
    				end try
    			end repeat
    		end timeout
    	end tell
    	return ""
    end titleof

    on notesof(s)
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			set np to notes page of s
    			repeat with j from 1 to (count of shapes of np)
    				try
    					set sh to shape j of np
    					if (placeholder type of place holder format of sh) is placeholder type body placeholder then
    						return content of text range of text frame of sh
    					end if
    				on error msg number n
    					my rethrowfatal(msg, n)
    				end try
    			end repeat
    		end timeout
    	end tell
    	return ""
    end notesof

    on hiddenof(s)
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			try
    				return hidden of slide show transition of s
    			on error msg number n
    				my rethrowfatal(msg, n)
    			end try
    		end timeout
    	end tell
    	return false
    end hiddenof

    on deckinfo()
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			set p to my currentpresentation()
    			if p is missing value then return {"", "", 0}
    			return {name of p, my deckkey(p), count of slides of p}
    		end timeout
    	end tell
    end deckinfo

    -- Un blocco di slide alla volta, così l'app resta reattiva tra un blocco e l'altro.
    on readslides(a, b)
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			set p to my currentpresentation()
    			if p is missing value then error "Nessuna presentazione aperta" number 1003
    			set total to count of slides of p
    			if b > total then set b to total
    			set slideList to {}
    			repeat with i from a to b
    				set s to slide i of p
    				set end of slideList to {my titleof(s), my notesof(s), my hiddenof(s), slide ID of s}
    			end repeat
    			return {my deckkey(p), slideList}
    		end timeout
    	end tell
    end readslides

    on gonext()
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			go to next slide (my showview())
    		end timeout
    	end tell
    	return true
    end gonext

    on goprev()
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			go to previous slide (my showview())
    		end timeout
    	end tell
    	return true
    end goprev

    on gofirst()
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			go to first slide (my showview())
    		end timeout
    	end tell
    	return true
    end gofirst

    -- "go to slide" non accetta la vista presentazione: si avanza/arretra di pochi passi per volta.
    -- Restituisce {slide raggiunta, arrivato?, passi fermi}. La slide di arrivo non può essere nascosta,
    -- quindi avanti/indietro (che saltano le nascoste) ci arrivano senza mai superarla.
    -- `stuck` conta i passi indietro senza cambio di slide (animazioni annullate): oltre il numero di
    -- animazioni della slide vuol dire che la presentazione è partita da lì e non si può tornare prima.
    on steptoward(n, maxsteps, stuck)
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			set v to my showview()
    			set p to presentation of slide show window 1
    			if n < 1 or n > (count of slides of p) then error "Slide inesistente" number 1002
    			if hidden of slide show transition of slide n of p then error "Slide nascosta" number 1005
    			set idx to slide index of slide of v
    			if idx = n then return {idx, true, 0}
    			if n = 1 then
    				go to first slide v
    				set idx to slide index of slide of v
    				if idx = 1 then return {1, true, 0}
    				error "Prima della slide di partenza" number 1009
    			end if
    			repeat maxsteps times
    				set previdx to idx
    				if idx < n then
    					go to next slide v
    				else
    					go to previous slide v
    				end if
    				try
    					set idx to slide index of slide of v
    				on error msg number e
    					my rethrowfatal(msg, e)
    					error "Fine presentazione raggiunta" number 1006
    				end try
    				if idx = n then return {idx, true, 0}
    				if (previdx < n and idx > n) or (previdx > n and idx < n) then error "Salto non riuscito" number 1007
    				if idx = previdx and idx > n then
    					set stuck to stuck + 1
    					if stuck > (print steps of slide idx of p) then error "Prima della slide di partenza" number 1009
    				else
    					set stuck to 0
    				end if
    			end repeat
    			return {idx, false, stuck}
    		end timeout
    	end tell
    end steptoward

    -- Avvio da una slide: PowerPoint per Mac lo permette solo con un intervallo di slide (N…ultima).
    -- Le impostazioni della presentazione vengono ripristinate subito: la presentazione in corso non ne
    -- risente e il file resta com'era. Limite di PowerPoint: non si torna prima della slide di partenza.
    on startfrom(n)
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 10 seconds
    			if (count of slide show windows) > 0 then error "Presentazione già avviata" number 1008
    			if (count of presentations) = 0 then error "Nessuna presentazione aperta" number 1003
    			set p to active presentation
    			set total to count of slides of p
    			if n < 1 or n > total then error "Slide inesistente" number 1002
    			if hidden of slide show transition of slide n of p then error "Slide nascosta" number 1005
    			set ss to slide show settings of p
    			if n = 1 then
    				run slide show ss
    				return true
    			end if
    			set oldrange to range type of ss
    			set oldstart to starting slide of ss
    			set oldend to ending slide of ss
    			try
    				set range type of ss to slide show range
    				set ending slide of ss to total
    				set starting slide of ss to n
    				run slide show ss
    			on error msg number e
    				my restoresettings(ss, oldrange, oldstart, oldend)
    				error msg number e
    			end try
    			my restoresettings(ss, oldrange, oldstart, oldend)
    		end timeout
    	end tell
    	return true
    end startfrom

    -- Miniature: PowerPoint (in sandbox) esporta un PDF nel proprio contenitore. Le slide nascoste
    -- non vengono esportate. Funziona solo con presentazioni già salvate almeno una volta.
    on exportpdf(target)
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 90 seconds
    			set p to my currentpresentation()
    			if p is missing value then error "Nessuna presentazione aperta" number 1003
    			save p in (POSIX file target) as save as PDF
    			return my deckkey(p)
    		end timeout
    	end tell
    end exportpdf

    -- Per tornare prima della slide di partenza bisogna chiudere e riavviare la presentazione.
    on restartfrom(n)
    	my endshow()
    	delay 0.6
    	return my startfrom(n)
    end restartfrom

    on restoresettings(ss, oldrange, oldstart, oldend)
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			try
    				set starting slide of ss to oldstart
    				set ending slide of ss to oldend
    				set range type of ss to oldrange
    			end try
    		end timeout
    	end tell
    end restoresettings

    on startshow()
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 10 seconds
    			if (count of slide show windows) > 0 then return true
    			if (count of presentations) = 0 then error "Nessuna presentazione aperta" number 1003
    			run slide show (slide show settings of active presentation)
    		end timeout
    	end tell
    	return true
    end startshow

    on endshow()
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 5 seconds
    			if (count of slide show windows) > 0 then exit slide show (slideshow view of slide show window 1)
    		end timeout
    	end tell
    	return true
    end endshow

    on toggleblack()
    	my ensurerunning()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			set v to my showview()
    			if (slide state of v) is slide show state black screen then
    				set slide state of v to slide show state running
    			else
    				set slide state of v to slide show state black screen
    			end if
    		end timeout
    	end tell
    	return true
    end toggleblack
    """
}
