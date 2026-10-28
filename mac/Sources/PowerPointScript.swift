/// Script AppleScript eseguito dentro l'app (NSAppleScript): parla solo con PowerPoint,
/// nessun processo esterno, nessun accesso a System Events o alla tastiera.
enum PowerPointScript {
    static let source = """
    on showview()
    	tell application id "com.microsoft.Powerpoint"
    		if (count of slide show windows) = 0 then error "Presentazione non avviata" number 1001
    		return slideshow view of slide show window 1
    	end tell
    end showview

    on deckkey(p)
    	tell application id "com.microsoft.Powerpoint"
    		return (full name of p) & "#" & (count of slides of p)
    	end tell
    end deckkey

    on currentpresentation()
    	tell application id "com.microsoft.Powerpoint"
    		if (count of slide show windows) > 0 then return presentation of slide show window 1
    		if (count of presentations) > 0 then return active presentation
    		return missing value
    	end tell
    end currentpresentation

    on readstate()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 2 seconds
    			if (count of slide show windows) > 0 then
    				set w to slide show window 1
    				set p to presentation of w
    				set v to slideshow view of w
    				set idx to 0
    				set isBlack to false
    				set el to 0
    				try
    					set idx to slide index of slide of v
    				end try
    				try
    					set isBlack to ((slide state of v) is slide show state black screen)
    				end try
    				try
    					set el to presentation elapsed time of v
    				end try
    				return {true, idx, count of slides of p, isBlack, el, my deckkey(p)}
    			end if
    			try
    				set p to my currentpresentation()
    				if p is not missing value then return {false, 0, count of slides of p, false, 0, my deckkey(p)}
    			end try
    			return {false, 0, 0, false, 0, ""}
    		end timeout
    	end tell
    end readstate

    on titleof(s)
    	tell application id "com.microsoft.Powerpoint"
    		repeat with j from 1 to (count of shapes of s)
    			try
    				set sh to shape j of s
    				set t to placeholder type of place holder format of sh
    				if t is placeholder type title placeholder or t is placeholder type center title placeholder or t is placeholder type vertical title placeholder then
    					return content of text range of text frame of sh
    				end if
    			end try
    		end repeat
    	end tell
    	return ""
    end titleof

    on notesof(s)
    	tell application id "com.microsoft.Powerpoint"
    		set np to notes page of s
    		repeat with j from 1 to (count of shapes of np)
    			try
    				set sh to shape j of np
    				if (placeholder type of place holder format of sh) is placeholder type body placeholder then
    					return content of text range of text frame of sh
    				end if
    			end try
    		end repeat
    	end tell
    	return ""
    end notesof

    on hiddenof(s)
    	tell application id "com.microsoft.Powerpoint"
    		try
    			return hidden of slide show transition of s
    		end try
    	end tell
    	return false
    end hiddenof

    on readdeck()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 30 seconds
    			set p to my currentpresentation()
    			if p is missing value then return {"", "", {}}
    			set slideList to {}
    			repeat with i from 1 to (count of slides of p)
    				set s to slide i of p
    				set slideList to slideList & {{my titleof(s), my notesof(s), my hiddenof(s)}}
    			end repeat
    			return {name of p, my deckkey(p), slideList}
    		end timeout
    	end tell
    end readdeck

    on gonext()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			go to next slide (my showview())
    		end timeout
    	end tell
    	return true
    end gonext

    on goprev()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			go to previous slide (my showview())
    		end timeout
    	end tell
    	return true
    end goprev

    on gofirst()
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 3 seconds
    			go to first slide (my showview())
    		end timeout
    	end tell
    	return true
    end gofirst

    -- "go to slide" non accetta la vista presentazione: si avanza/arretra fino alla slide voluta.
    on goslide(n)
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 20 seconds
    			set v to my showview()
    			set total to count of slides of presentation of slide show window 1
    			if n < 1 or n > total then error "Slide inesistente" number 1002
    			if n = 1 then
    				go to first slide v
    				return true
    			end if
    			set idx to slide index of slide of v
    			if idx < n then
    				repeat 2000 times
    					go to next slide v
    					set idx to slide index of slide of v
    					if idx >= n then exit repeat
    				end repeat
    			else if idx > n then
    				repeat 2000 times
    					go to previous slide v
    					set idx to slide index of slide of v
    					if idx <= n then exit repeat
    				end repeat
    			end if
    			return idx = n
    		end timeout
    	end tell
    end goslide

    on startshow()
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
    	tell application id "com.microsoft.Powerpoint"
    		with timeout of 5 seconds
    			if (count of slide show windows) > 0 then exit slide show (slideshow view of slide show window 1)
    		end timeout
    	end tell
    	return true
    end endshow

    on toggleblack()
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
