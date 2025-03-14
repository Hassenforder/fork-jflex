/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 * JFlex 1.9.0-SNAPSHOT                                                    *
 * Copyright (C) 1998-2018  Gerwin Klein <lsf@jflex.de>                    *
 * All rights reserved.                                                    *
 *                                                                         *
 * License: BSD                                                            *
 *                                                                         *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

package jflex.core;

import java_cup.runtime.Symbol;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import jflex.core.unicode.IntCharSet;
import jflex.core.unicode.UnicodeProperties;
import jflex.l10n.ErrorMessages;
import jflex.logging.Out;
import jflex.option.Options;
import jflex.performance.Timer;
import jflex.scanner.ScannerException;
import jflex.skeleton.Skeleton;

%%

%final
%public
%class LexScan
%extends AbstractLexScan
%implements sym, java_cup.runtime.Scanner
%function next_token

%type Symbol
%unicode

%column
%line

%eofclose

%state COMMENT, STATELIST, MACROS, REGEXPSTART
%state REGEXP, JAVA_CODE, STATES, STRING_CONTENT
%state CHARCLASS, COPY, REPEATEXP, EATWSPNL
%state CTOR_ARG, REGEXP_CODEPOINT_SEQUENCE
%state STRING_CODEPOINT_SEQUENCE, CHARCLASS_CODEPOINT

%cupdebug

%{

  int balance = 0;
  int commentbalance = 0;
  int action_line = 0;
  StringBuilder actionText = new StringBuilder();

  boolean isYYEOF;
  boolean notUnix;
  boolean caseless;
  boolean inclusive_states;

  int nextState;

  boolean macroDefinition;

  Timer t = new Timer();

  @Override
  protected int lexLine() {
    return yyline;
  }

  @Override
  protected int lexColumn() {
    return yycolumn;
  }

  @Override
  protected String lexText() {
    return yytext();
  }

  @Override
  protected void lexPushStream(File f) throws IOException {
    // yypushStream in skeleton.nested
    yypushStream(Files.newBufferedReader(f.toPath(), Options.encoding));
  }
%}

%init{
  states.insert("YYINITIAL", true);
%init}


Digit      = [0-9]
HexDigit   = [0-9a-fA-F]
OctDigit   = [0-7]

Number     = {Digit}+
HexNumber  = \\ x {HexDigit} {2}
OctNumber  = \\ [0-3]? {OctDigit} {1, 2}

// Unicode4 can encode chars only in the BMP with the 16 bits provided by its
// 4 hex digits.
Unicode4  = \\ u {HexDigit} {4}

// Unicode6 can encode all Unicode chars, both in the BMP and in the
// supplementary planes -- only 21 bits are required as of Unicode 5.0,
// but its six hex digits provide 24 bits.
Unicode6  = \\ U {HexDigit} {6}

// see http://www.unicode.org/unicode/reports/tr18/
WSP        = [ \t\b]
WSPNL      = [\u2028\u2029\u000A\u000B\u000C\u000D\u0085\t\b\ ]
NWSPNL     = [^\u2028\u2029\u000A\u000B\u000C\u000D\u0085\t\b\ ]
NL         = [\u2028\u2029\u000A\u000B\u000C\u000D\u0085] | \u000D\u000A
NNL        = [^\u2028\u2029\u000A\u000B\u000C\u000D\u0085]

Ident      = {IdentStart} {IdentPart}*
QualIdent  = {Ident} ( {WSP}* "." {WSP}* {Ident} )*
QUIL       = {QualIdent} ( {WSP}* "," {WSP}* {QualIdent} )*
Array      = "[" {WSP}* "]"
ParamPart  = {IdentStart}|{IdentPart}|"<"|">"|","|{WSP}|"&"|"?"|"."
GenParam   = "<" {ParamPart}+ ">"
ClassT     = {Ident} ({WSP}* {GenParam})?
QClassT    = {QualIdent} ({WSP}* {GenParam})?
ArrType    = ({GenParam} {WSP}*)? {QClassT} ({WSP}* {Array})*

IdentStart = [:jletter:]
IdentPart  = [:jletterdigit:]

JFlexCommentChar = [^*/]|"/"+[^*/]|"*"+[^*/]
JFlexComment = {JFlexCommentChar}+

/* Java comments */
JavaComment = {TraditionalComment}|{EndOfLineComment}
TraditionalComment = "/*"{CommentContent}\*+"/"
EndOfLineComment = "//".*{NL}

CommentContent = ([^*]|\*+[^*/])*

StringCharacter = [^\u2028\u2029\u000A\u000B\u000C\u000D\u0085\"\\]

CharLiteral = \'([^\u2028\u2029\u000A\u000B\u000C\u000D\u0085\'\\]|{EscapeSequence})\'
StringLiteral = \"({StringCharacter}|{EscapeSequence})*\"

EscapeSequence = \\[^\u2028\u2029\u000A\u000B\u000C\u000D\u0085]|\\+u{HexDigit}{4}|\\[0-3]?{OctDigit}{1,2}

/* \\(b|t|n|f|r|\"|\'|\\|[0-3]?{OctDigit}{1,2}|u{HexDigit}{4}) */

JavaRest = [^\{\}\"\'/]|"/"[^*/]
JavaCode = ({JavaRest}|{StringLiteral}|{CharLiteral}|{JavaComment})+

DottedVersion =  [1-9][0-9]*(\.[0-9]+){0,2}

%%

<YYINITIAL> {
  "%%".*{NL}?              {
                             t.start();
                             yybegin(MACROS);
                             macroDefinition = true;
                             return symbol(USERCODE,userCode);
                           }
  .*{NL} | .+              { userCode.append(yytext()); }
  <<EOF>>                  { return symbol(EOF); }
}

<MACROS>   ("%{"|"%init{"|"%initthrow{"|"%eof{"|"%eofthrow{"|"%yylexthrow{"|"%eofval{").*{NL}
                                     { string.setLength(0); yybegin(COPY); }
<COPY> {
  "%}".*{NL}                    { classCode = conc(classCode,string);  yybegin(MACROS);  }
  "%init}".*{NL}                { initCode = conc(initCode,string);    yybegin(MACROS);  }
  "%initthrow}".*{NL}           { initThrow = concExc(initThrow,string);  yybegin(MACROS); }
  "%eof}".*{NL}                 { eofCode = conc(eofCode,string); yybegin(MACROS); }
  "%eofthrow}".*{NL}            { eofThrow = concExc(eofThrow,string); yybegin(MACROS); }
  "%yylexthrow}".*{NL}          { lexThrow.add(string.toString()); yybegin(MACROS); }
  "%eofval}".*{NL}              { eofVal = string.toString(); yybegin(MACROS); }

  .*{NL}                        { string.append(yytext()); }

  <<EOF>>                       { throw new ScannerException(file,ErrorMessages.EOF_IN_MACROS); }
}


<MACROS> ^"%s" ("tate" "s"?)? {WSP}+   { inclusive_states = true; yybegin(STATELIST); }
<MACROS> ^"%x" ("state" "s"?)? {WSP}+  { inclusive_states = false; yybegin(STATELIST); }
<STATELIST> {
  {Ident}                             { states.insert(yytext(),inclusive_states); }
  ([\ \t]*","[\ \t]*)|([\ \t]+)       { }
  {NL}                                { yybegin(MACROS);  }
  <<EOF>>                       { throw new ScannerException(file,ErrorMessages.EOF_IN_MACROS); }
}

<MACROS> {
  "%char"                     { charCount = true;  }
  "%line"                     { lineCount = true;  }
  "%column"                   { columnCount = true; }
  "%byaccj"                   { isInteger = true;
                                if (eofVal == null)
                                  eofVal = "return 0;";
                                eofclose = true;
                              }
  "%cupJHMH"                  { cupJHMHCompatible = true;
								cupSymbol="Sym";
                                isImplementing = "com.github.jhoenicke.javacup.runtime.Scanner";
                                lineCount = true;
                                columnCount = true;
                                if (functionName == null)
                                  functionName = "next_token";
                                if (tokenType == null)
                                  tokenType = "Symbol";
                                if (eofVal == null)
                                  eofVal = "return symbol(ETerminal.EOF);";
                                if (!Options.jlex) eofclose = true;
                                // %unicode:
                                populateDefaultVersionUnicodeProperties();
                                initUnicodeCharClasses();
                              }
  "%mode"{WSP}+("STD"|"MAP"){WSP}*     { Options.mode = Options.Mode.valueOf(yytext().substring(6).trim()); }
  "%cup2"                     { cup2Compatible = true;
                                isImplementing = concExc(isImplementing, "Scanner");
                                lineCount = true;
                                columnCount = true;
                                if (functionName == null)
                                  functionName = "readNextTerminal";
                                if (tokenType == null)
                                  tokenType = "ScannerToken<? extends Object>";
                                if (eofVal == null)
                                  eofVal = "return token(SpecialTerminals.EndOfInputStream);";
                                if (!Options.jlex) eofclose = true;
                                // %unicode:
                                populateDefaultVersionUnicodeProperties();
                                initUnicodeCharClasses();
                              }
  "%cup"                      { cupCompatible = true;
                                isImplementing = concExc(isImplementing, "java_cup.runtime.Scanner");
                                if (functionName == null)
                                  functionName = "next_token";
                                if (tokenType == null)
                                  tokenType = "java_cup.runtime.Symbol";
                                if (eofVal == null)
                                  eofVal = "return new java_cup.runtime.Symbol("+cupSymbol+".EOF);";
                                if (!Options.jlex) eofclose = true;
                              }
  "%cupsym"{WSP}+{QualIdent} {WSP}*  { cupSymbol = yytext().substring(8).trim();
                                if (cupCompatible) Out.warning(ErrorMessages.CUPSYM_AFTER_CUP, yyline); }
  "%cupsym"{WSP}+{NNL}*       { throw new ScannerException(file,ErrorMessages.QUIL_CUPSYM, yyline); }
  "%cupdebug"                 { cupDebug = true; }
  "%eofclose"({WSP}+"true")?  { eofclose = true; }
  "%eofclose"({WSP}+"false")  { eofclose = false; }
  "%package"{WSP}+{QualIdent} {WSP}*     { packageName = yytext().substring(9).trim();  }
  "%class"{WSP}+{ClassT} {WSP}*     { className = yytext().substring(7).trim();  }
  "%ctorarg"{WSP}+{ArrType}{WSP}+   { yybegin(CTOR_ARG); ctorTypes.add(yytext().substring(8).trim()); }
  "%function"{WSP}+{Ident} {WSP}*   { functionName = yytext().substring(10).trim(); }
  "%type"{WSP}+{ArrType} {WSP}*     { tokenType = yytext().substring(6).trim(); }
  "%integer"|"%int"           { isInteger = true;  }
  "%intwrap"                  { isIntWrap = true;  }
  "%yyeof"                    { isYYEOF = true;  }
  "%notunix"                  { notUnix = true;  }
  "%7bit"                     { populateDefaultVersionUnicodeProperties();
                                charClasses.init(127, this); }
  "%full"|"%8bit"             { populateDefaultVersionUnicodeProperties();
                                charClasses.init(255, this); }
  "%16bit"                    { populateDefaultVersionUnicodeProperties();
                                initUnicodeCharClasses(); }
  "%unicode"({WSP}+{DottedVersion})? { String v = yytext().substring(8).trim();
                                       if (v.length() == 0) {
                                         populateDefaultVersionUnicodeProperties();
                                       } else {
                                         try {
                                           unicodeProperties = new UnicodeProperties(v);
                                         } catch (UnicodeProperties.UnsupportedUnicodeVersionException e) {
                                           throw new ScannerException
                                             (file, ErrorMessages.UNSUPPORTED_UNICODE_VERSION, yyline);
                                         }
                                       }
                                       initUnicodeCharClasses();
                                     }

  "%caseless"|"%ignorecase"   { caseless = true; }
  "%implements"{WSP}+.*       { isImplementing = concExc(isImplementing, yytext().substring(12).trim());  }
  "%extends"{WSP}+{QClassT}{WSP}* { isExtending = yytext().substring(9).trim(); }
  "%public"                   { isPublic = true; }
  "%apiprivate"               { visibility = "private"; Skeleton.makePrivate(); }
  "%final"                    { isFinal = true; }
  "%abstract"                 { isAbstract = true; }
  "%debug"                    { debugOption = true; }
  "%standalone"               { standalone = true; isInteger = true; }
  "%pack"                     { /* no-op - this is the only generation method */ }
  "%include" {WSP}+ .*        { includeFile(yytext().substring(9).trim()); }
  "%buffer" {WSP}+ {Number} {WSP}*   { bufferSize = Integer.parseInt(yytext().substring(8).trim()); }
  "%buffer" {WSP}+ {NNL}*     { throw new ScannerException(file,ErrorMessages.NO_BUFFER_SIZE, yyline); }
  "%initthrow" {WSP}+ {QUIL} {WSP}* { initThrow = concExc(initThrow,yytext().substring(11).trim()); }
  "%initthrow" {WSP}+ {NNL}*  { throw new ScannerException(file,ErrorMessages.QUIL_INITTHROW, yyline); }
  "%eofthrow"  {WSP}+ {QUIL} {WSP}*  { eofThrow = concExc(eofThrow,yytext().substring(10).trim()); }
  "%eofthrow"  {WSP}+ {NNL}*  { throw new ScannerException(file,ErrorMessages.QUIL_EOFTHROW, yyline); }
  "%yylexthrow"{WSP}+ {QUIL} {WSP}* {JavaComment}? { lexThrow.add(yytext().substring(12).trim()); }
  "%throws"    {WSP}+ {QUIL} {WSP}*  { lexThrow.add(yytext().substring(8).trim()); }
  "%yylexthrow"{WSP}+ {NNL}*  { throw new ScannerException(file,ErrorMessages.QUIL_YYLEXTHROW, yyline); }
  "%throws"    {WSP}+ {NNL}*  { throw new ScannerException(file,ErrorMessages.QUIL_THROW, yyline); }
  "%scanerror" {WSP}+ {QualIdent} {WSP}* { scanErrorException = yytext().substring(11).trim(); }
  "%scanerror" {WSP}+ {NNL}*  { throw new ScannerException(file,ErrorMessages.QUIL_SCANERROR, yyline); }

  {Ident}                     { return symbol(IDENT, yytext()); }
  "="{WSP}*                   { if (null == unicodeProperties) {
                                  populateDefaultVersionUnicodeProperties();
                                  initUnicodeCharClasses();
                                }
                                yybegin(REGEXP);
                                return symbol(EQUALS);
                              }

  "/*"                        { nextState = MACROS; yybegin(COMMENT); }

  {EndOfLineComment}          { }

  ^"%%" {NNL}*                { if (null == unicodeProperties) {
                                  populateDefaultVersionUnicodeProperties();
                                  initUnicodeCharClasses();
                                }
                                macroDefinition = false;
                                yybegin(REGEXPSTART);
                                return symbol(DELIMITER);
                              }
  "%"{Ident}                  { throw new ScannerException(file,ErrorMessages.UNKNOWN_OPTION, yyline, yycolumn); }
  "%"                         { throw new ScannerException(file,ErrorMessages.UNKNOWN_OPTION, yyline, yycolumn); }
  ^{WSP}+"%"                  { Out.warning(ErrorMessages.NOT_AT_BOL, yyline); yypushback(1); }

  {WSP}+                      { }
  {NL}+                       { }
  <<EOF>>                     { if ( yymoreStreams() ) {
                                  file = popFile();
                                  yypopStream();
                                }
                                else
                                  throw new ScannerException(file,ErrorMessages.EOF_IN_MACROS);
                              }
}

<CTOR_ARG> {
  {Ident} {WSP}*   { yybegin(MACROS); ctorArgs.add(yytext().trim()); }
  [^]              { throw new ScannerException(file,ErrorMessages.CTOR_ARG,yyline,yycolumn); }
}

<REGEXPSTART> {
  ^ {WSP}* "%include" {WSP}+ .*  { includeFile(yytext().trim().substring(9).trim()); }
  {WSP}* "/*"                    { nextState = REGEXPSTART; yybegin(COMMENT); }
  {WSP}* "<"                     { yybegin(STATES); return symbol_countUpdate(LESSTHAN, null); }
  {WSP}* "}"                     { return symbol_countUpdate(RBRACE, null); }
  {WSP}* "//" {NNL}*             { }
  {WSP}* "<<EOF>>" {WSPNL}* "{"  { actionText.setLength(0); yybegin(JAVA_CODE);
                                   Symbol s = symbol_countUpdate(EOFRULE, null);
                                   action_line = s.left+1;
                                   return s;
                                 }
  {WSP}* "<<EOF>>" {WSPNL}*/"|"  { yybegin(REGEXP); return symbol(EOFRULE); }
  ^ {WSP}* {NWSPNL}              { yypushback(yylength()); yybegin(REGEXP); }
  {WSP} | {NL}                   { }
}

<STATES> {
  {Ident}                     { return symbol(IDENT, yytext()); }
  ","                         { return symbol(COMMA); }
  {WSPNL}+                    { }

  // "{" will be caught in REGEXP
  ">"{WSPNL}*                 { yybegin(REGEXP); return symbol(MORETHAN); }

  <<EOF>>                     { throw new ScannerException(file,ErrorMessages.EOF_IN_STATES); }
}


<REGEXP> {
  "<<EOF>>" {WSPNL}+ "{"  { actionText.setLength(0); yybegin(JAVA_CODE); action_line = yyline+1; return symbol(EOFRULE); }
  "<<EOF>>"               { throw new ScannerException(file,ErrorMessages.EOF_WO_ACTION); }

  {WSPNL}*"|"{WSP}*$      { if (macroDefinition) {
                              yybegin(EATWSPNL);
                              return symbol(BAR);
                            }
                            else {
                              yybegin(REGEXPSTART);
                              return symbol(NOACTION);
                            }
                          }

  // stategroup
  "{"            { yybegin(REGEXPSTART); return symbol(LBRACE); }

  {WSPNL}*"|"    { return symbol(BAR); }

  {WSPNL}*\"     { string.setLength(0); nextState = REGEXP; yybegin(STRING_CONTENT); }
  {WSPNL}*"\\u{" { string.setLength(0); yybegin(REGEXP_CODEPOINT_SEQUENCE); }
  {WSPNL}*"!"    { return symbol(BANG); }
  {WSPNL}*"~"    { return symbol(TILDE); }
  {WSPNL}*"("    { return symbol(OPENBRACKET); }
  {WSPNL}*")"    { return symbol(CLOSEBRACKET); }
  {WSPNL}*"*"    { return symbol(STAR); }
  {WSPNL}*"+"    { return symbol(PLUS); }
  {WSPNL}*"?"    { return symbol(QUESTION); }
  {WSPNL}*"$"    { return symbol(DOLLAR); }
  {WSPNL}*"^"    { bolUsed = true; return symbol(HAT); }
  {WSPNL}*"."    { return symbol(POINT); }
  {WSPNL}*"\\R"  { return symbol(NEWLINE); }
  {WSPNL}*"["    { yybegin(CHARCLASS); return symbol(OPENCLASS); }
  {WSPNL}*"/"    { return symbol(LOOKAHEAD); }

  {WSPNL}* "{" {WSP}* {Ident} {WSP}* "}" { return symbol_countUpdate(MACROUSE, makeMacroIdent()); }
  {WSPNL}* "{" {WSP}* {Number}   { yybegin(REPEATEXP);
                                   return symbol(REPEAT,
                                                 Integer.valueOf(yytext().trim().substring(1).trim()));
                                 }

  {WSPNL}+ "{"    { actionText.setLength(0); yybegin(JAVA_CODE); action_line = yyline+1; return symbol(REGEXPEND); }
  {NL}            { if (macroDefinition) { yybegin(MACROS); } return symbol(REGEXPEND); }

  {WSPNL}*"/*"    { nextState = REGEXP; yybegin(COMMENT); }

  {WSPNL}*"//"{NNL}*  { }

  {WSP}+          { }

  <CHARCLASS> {
    {WSPNL}*"[:jletter:]"      { return symbol(JLETTERCLASS); }
    {WSPNL}*"[:jletterdigit:]" { return symbol(JLETTERDIGITCLASS); }
    {WSPNL}*"[:letter:]"       { return symbol(LETTERCLASS); }
    {WSPNL}*"[:uppercase:]"    { return symbol(UPPERCLASS); }
    {WSPNL}*"[:lowercase:]"    { return symbol(LOWERCLASS); }
    {WSPNL}*"[:digit:]"        { return symbol(DIGITCLASS); }
    {WSPNL}*"\\d"              { return symbol(DIGITCLASS); }
    {WSPNL}*"\\D"              { return symbol(DIGITCLASSNOT); }
    {WSPNL}*"\\s"              { return symbol(WHITESPACECLASS); }
    {WSPNL}*"\\S"              { return symbol(WHITESPACECLASSNOT); }
    {WSPNL}*"\\w"              { return symbol(WORDCLASS); }
    {WSPNL}*"\\W"              { return symbol(WORDCLASSNOT); }
    {WSPNL}*"\\p{"[^}]*"}"     { String trimmedText = yytext().trim();
                                 String propertyValue = trimmedText.substring(3,trimmedText.length()-1);
                                 IntCharSet set = unicodeProperties.getIntCharSet(propertyValue);
                                 if (null == set) {
                                   throw new ScannerException(file,ErrorMessages.INVALID_UNICODE_PROPERTY, yyline, yycolumn + 3);
                                 }
                                 return symbol(UNIPROPCCLASS, set);
                               }
    {WSPNL}*"\\P{"[^}]*"}"     { String trimmedText = yytext().trim();
                                 String propertyValue = trimmedText.substring(3,trimmedText.length()-1);
                                 IntCharSet set = unicodeProperties.getIntCharSet(propertyValue);
                                 if (null == set) {
                                   throw new ScannerException(file,ErrorMessages.INVALID_UNICODE_PROPERTY, yyline, yycolumn + 3);
                                 }
                                 return symbol(UNIPROPCCLASSNOT, set);
                               }
  }

  . { return symbol(CHAR, yytext().codePointAt(0)); }
}

<EATWSPNL> {WSPNL}+  { yybegin(REGEXP); }


<REPEATEXP> {
  "}"          { yybegin(REGEXP); return symbol(RBRACE); }
  "," {WSP}* {Number}  { return symbol(REPEAT, Integer.valueOf(yytext().substring(1).trim())); }
  {WSP}+       { }

  <<EOF>>                 { throw new ScannerException(file,ErrorMessages.EOF_IN_REGEXP); }
}

<CHARCLASS> {
  "{"{Ident}"}" { return symbol(MACROUSE, yytext().substring(1,yylength()-1)); }
  "["     { balance++; return symbol(OPENCLASS); }
  "]"     { if (balance > 0) balance--; else yybegin(REGEXP); return symbol(CLOSECLASS); }
  "^"     { return symbol(HAT); }
  "-"     { return symbol(DASH); }
  "--"    { return symbol(DIFFERENCE); }
  "&&"    { return symbol(INTERSECTION); }
  "||"    { /* union is the default operation - '||' can be ignored */ }
  "~~"    { return symbol(SYMMETRICDIFFERENCE); }
  "\\u{"  { yybegin(CHARCLASS_CODEPOINT); }

  // this is a hack to keep JLex compatibilty with char class
  // expressions like [+-]
  "-]"    { yypushback(1); yycolumn--; return symbol(CHAR, (int)'-'); }

  \"      { string.setLength(0); nextState = CHARCLASS; yybegin(STRING_CONTENT); }

  .       { return symbol(CHAR, yytext().codePointAt(0)); }

  \n      { throw new ScannerException(file,ErrorMessages.EOL_IN_CHARCLASS,yyline,yycolumn); }

  <<EOF>> { throw new ScannerException(file,ErrorMessages.EOF_IN_REGEXP); }
}

<STRING_CONTENT> {
  \"       { yybegin(nextState); return symbol(STRING, string.toString()); }
  \\\"     { string.append('\"'); }
  [^\"\\\u2028\u2029\u000A\u000B\u000C\u000D\u0085]+ { string.append(yytext()); }

  {NL}     { throw new ScannerException(file,ErrorMessages.UNTERMINATED_STR, yyline, yycolumn); }

  {HexNumber} { string.append( (char) Integer.parseInt(yytext().substring(2,yylength()), 16)); }
  {OctNumber} { string.append( (char) Integer.parseInt(yytext().substring(1,yylength()), 8)); }
  {Unicode4}  { string.append( (char) Integer.parseInt(yytext().substring(2,yylength()), 16)); }
  {Unicode6}  { int codePoint = Integer.parseInt(yytext().substring(2,yylength()), 16);
                if (codePoint <= unicodeProperties.getMaximumCodePoint()) {
                  string.append(Character.toChars(codePoint));
                } else {
                  throw new ScannerException(file,ErrorMessages.CODEPOINT_OUT_OF_RANGE, yyline, yycolumn+2);
                }
              }

  "\\u{"      { yybegin(STRING_CODEPOINT_SEQUENCE); }

  \\b { string.append('\b'); }
  \\n { string.append('\n'); }
  \\t { string.append('\t'); }
  \\f { string.append('\f'); }
  \\r { string.append('\r'); }

  \\. { string.append(yytext().substring(1, yytext().offsetByCodePoints(1, 1))); }

  <<EOF>>     { throw new ScannerException(file,ErrorMessages.EOF_IN_STRING); }
}


<REGEXP, CHARCLASS> {
  {HexNumber} { return symbol(CHAR, Integer.parseInt(yytext().substring(2,yylength()), 16)); }
  {OctNumber} { return symbol(CHAR, Integer.parseInt(yytext().substring(1,yylength()), 8)); }
  {Unicode4}  { return symbol(CHAR, Integer.parseInt(yytext().substring(2,yylength()), 16)); }
  {Unicode6}  { int codePoint = Integer.parseInt(yytext().substring(2,yylength()), 16);
                if (codePoint <= unicodeProperties.getMaximumCodePoint()) {
                  return symbol(CHAR, codePoint);
                } else {
                  throw new ScannerException(file,ErrorMessages.CODEPOINT_OUT_OF_RANGE, yyline, yycolumn+2);
                }
              }

  \\b { return symbol(CHAR, (int)'\b'); }
  \\n { return symbol(CHAR, (int)'\n'); }
  \\t { return symbol(CHAR, (int)'\t'); }
  \\f { return symbol(CHAR, (int)'\f'); }
  \\r { return symbol(CHAR, (int)'\r'); }

  \\. { return symbol(CHAR, yytext().codePointAt(1)); }
}


<JAVA_CODE> {
  "{"        { balance++; actionText.append('{'); }
  "}"        { if (balance > 0) {
                 balance--;
                 actionText.append('}');
               }
               else {
                 yybegin(REGEXPSTART);
                 Action a = new Action(actionText.toString(), action_line);
                 actions.add(a);
                 return symbol(ACTION, a);
               }
             }

  {JavaCode}     { actionText.append(yytext()); }

  <<EOF>>     { throw new ScannerException(file,ErrorMessages.EOF_IN_ACTION, action_line-1); }
}

<COMMENT> {

  "/"+ "*"  { commentbalance++; }
  "*"+ "/"  { if (commentbalance > 0)
                commentbalance--;
              else
                yybegin(nextState);
            }

  {JFlexComment} { /* ignore */ }

  <<EOF>>     { throw new ScannerException(file,ErrorMessages.EOF_IN_COMMENT); }
}

<REGEXP_CODEPOINT_SEQUENCE> {
  "}"             { yybegin(REGEXP); return symbol(STRING, string.toString()); }
  {HexDigit}{1,6} { int codePoint = Integer.parseInt(yytext(), 16);
                    if (codePoint <= unicodeProperties.getMaximumCodePoint()) {
                      string.append(Character.toChars(codePoint));
                    } else {
                      throw new ScannerException(file,ErrorMessages.CODEPOINT_OUT_OF_RANGE, yyline, yycolumn);
                    }
                  }
  {WSPNL}+        { }
  <<EOF>>         { throw new ScannerException(file,ErrorMessages.EOF_IN_REGEXP); }
}

<STRING_CODEPOINT_SEQUENCE> { // Specialized form: newlines disallowed, and doesn't return a symbol
  "}"             { yybegin(STRING_CONTENT); }
  {HexDigit}{1,6} { int codePoint = Integer.parseInt(yytext(), 16);
                    if (codePoint <= unicodeProperties.getMaximumCodePoint()) {
                      string.append(Character.toChars(codePoint));
                    } else {
                      throw new ScannerException(file, ErrorMessages.CODEPOINT_OUT_OF_RANGE, yyline, yycolumn);
                    }
                  }
  {NL}            { throw new ScannerException(file,ErrorMessages.UNTERMINATED_STR, yyline, yycolumn); }
  {WSP}+          { }
  <<EOF>>         { throw new ScannerException(file,ErrorMessages.EOF_IN_STRING); }
}

<CHARCLASS_CODEPOINT> { // Specialized form: only one codepoint allowed, no whitespace allowed
  {HexDigit}{1,6} "}" { int codePoint = Integer.parseInt(yytext().substring(0, yylength() - 1), 16);
                        if (codePoint <= unicodeProperties.getMaximumCodePoint()) {
                          yybegin(CHARCLASS);
                          return symbol(CHAR, codePoint);
                        } else {
                          throw new ScannerException(file, ErrorMessages.CODEPOINT_OUT_OF_RANGE, yyline, yycolumn);
                        }
                      }
  <<EOF>>             { throw new ScannerException(file,ErrorMessages.EOF_IN_REGEXP); }
}

.  { throw new ScannerException(file,ErrorMessages.UNEXPECTED_CHAR, yyline, yycolumn); }
\R { throw new ScannerException(file,ErrorMessages.UNEXPECTED_NL, yyline, yycolumn); }

<<EOF>>  { if ( yymoreStreams() ) {
             file = popFile();
             yypopStream();
           }
           else {
             return symbol(EOF);
           }
         }
