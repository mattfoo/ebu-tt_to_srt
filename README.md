# EBU-TT Subtitle to SRT converter

# EBU-TT Subtitles:

For full specs see: <http://bbc.github.io/subtitle-guidelines/>

```
	<!--Profile: EBU-TT-D-Basic-DE--><tt:tt xmlns:tt="http://www.w3.org/ns/ttml"
	xmlns:ttp="http://www.w3.org/ns/ttml#parameter"
	xmlns:tts="http://www.w3.org/ns/ttml#styling"
	xmlns:ebuttm="urn:ebu:tt:metadata"
	xmlns:xs="http://www.w3.org/2001/XMLSchema"
	ttp:timeBase="media"
	ttp:cellResolution="50 30"
	xml:lang="de">
	<tt:head>
	<tt:metadata>
	<ebuttm:documentMetadata>
	<ebuttm:documentEbuttVersion>v1.0</ebuttm:documentEbuttVersion>
	</ebuttm:documentMetadata>
	</tt:metadata>
	<tt:styling>
	<tt:style xml:id="defaultStyle" tts:fontFamily="Verdana, Arial, Tiresias"
	tts:fontSize="160%"
	tts:lineHeight="125%"/>
	<tt:style xml:id="textLeft" tts:textAlign="left"/>
	<tt:style xml:id="textCenter" tts:textAlign="center"/>
	<tt:style xml:id="textRight" tts:textAlign="right"/>
	<tt:style xml:id="textBlack" tts:color="#000000" tts:backgroundColor="#000000c2"/>
	<tt:style xml:id="textBlue" tts:color="#0000ff" tts:backgroundColor="#000000c2"/>
	<tt:style xml:id="textGreen" tts:color="#00ff00" tts:backgroundColor="#000000c2"/>
	<tt:style xml:id="textCyan" tts:color="#00ffff" tts:backgroundColor="#000000c2"/>
	<tt:style xml:id="textRed" tts:color="#ff0000" tts:backgroundColor="#000000c2"/>
	<tt:style xml:id="textMagenta" tts:color="#ff00ff" tts:backgroundColor="#000000c2"/>
	<tt:style xml:id="textYellow" tts:color="#ffff00" tts:backgroundColor="#000000c2"/>
	<tt:style xml:id="textWhite" tts:color="#ffffff" tts:backgroundColor="#000000c2"/>
	</tt:styling>
	<tt:layout>
	<tt:region xml:id="bottom" tts:displayAlign="after" tts:origin="10% 10%"
	tts:extent="80% 80%"/>
	<tt:region xml:id="top" tts:displayAlign="before" tts:origin="10% 10%"
	tts:extent="80% 80%"/>
	</tt:layout>
	</tt:head>
	<tt:body>
	<tt:div style="defaultStyle">
	<tt:p xml:id="sub1" style="textCenter" region="bottom" begin="10:00:00.000"
	end="10:00:02.680">
	<tt:span style="textWhite">some text</tt:span>
	</tt:p>
	<tt:p xml:id="sub2" style="textCenter" region="bottom" begin="10:00:04.280"
	end="10:00:06.520">
	<tt:span style="textCyan">some more text</tt:span>
	</tt:p>
    ...
```

**Notice:** For whatever reason the timer begins with a 10:00:00:00 or 20:00:00:00
(see also "ebuttm:documentStartOfProgramme")! So you have to subtract 10 or 20 from
your hour value!!

# SRT:

```
1
00:00:24,000 --> 00:00:30,989
This programme contains some strong language and scenes of repetitive
```
