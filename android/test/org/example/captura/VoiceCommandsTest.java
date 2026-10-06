package org.example.captura;
import org.junit.Test;
import static org.junit.Assert.*;
public class VoiceCommandsTest {
    private String result(String text, double confidence) throws Exception {
        org.json.JSONArray words = new org.json.JSONArray();
        for (String word : text.split(" ")) words.put(new org.json.JSONObject().put("word",word).put("conf",confidence));
        return new org.json.JSONObject().put("text",text).put("result",words).toString();
    }
    @Test public void noteDelimitersNeedCompletePrefixedFinal() throws Exception {
        VoiceCommands c=new VoiceCommands();
        assertEquals(VoiceCommands.Command.NOTE,c.accept(result("lobo anota",1),2000));
        assertEquals(VoiceCommands.Command.DONE,c.accept(result("lobo listo",1),4000));
        for (String text:new String[]{"anota","listo","lobo anota comprar cafe","[unk] lobo listo","lobo listo [unk]"})
            assertEquals(VoiceCommands.Command.NONE,c.accept(result(text,1),6000));
    }
    @Test public void prefixedCommandsWork() throws Exception {
        VoiceCommands c=new VoiceCommands();
        assertEquals(VoiceCommands.Command.PAUSE,c.accept(result("lobo pausar captura",.96),2000));
        assertEquals(VoiceCommands.Command.START,c.accept(result("lobo iniciar captura",.96),2400));
        assertEquals(VoiceCommands.Command.STOP,c.accept(result("lobo detener por completo",.96),3000));
    }
    @Test public void conversationAndOldCommandsNeverArm() throws Exception {
        for(String s:new String[]{"lobo","pausar","pausar pausar","pausar captura","iniciar captura","empezar captura","reanudar captura","detener por completo","hice una pausa","voy a hacer una pausa","no puedo decir pausa","[unk]","dijo lobo pausar captura mañana","hola lobo pausar captura","lobot pausar captura"})
            assertEquals(s,VoiceCommands.Command.NONE,new VoiceCommands().accept(result(s,1),2000));
    }
    @Test public void standaloneWakeCannotArmLaterBareCommand() throws Exception {
        VoiceCommands c=new VoiceCommands();
        for(String s:new String[]{"hola lobo","lobo","iniciar captura","pausar captura"})
            assertEquals(VoiceCommands.Command.NONE,c.accept(result(s,1),10000));
    }
    @Test public void contextWithUnknownWordsRejects() throws Exception {
        VoiceCommands c=new VoiceCommands();
        for(String s:new String[]{"[unk] lobo iniciar captura","lobo iniciar captura [unk]","lobo hizo una pausa","lobo lobo","lobo pausar"})
            assertEquals(VoiceCommands.Command.NONE,c.accept(result(s,1),2000));
    }
    @Test public void partialOrWeakWordsCannotChangeState() throws Exception {
        VoiceCommands c=new VoiceCommands();
        assertEquals(VoiceCommands.Command.NONE,c.accept("{\"partial\":\"lobo pausar captura\"}",2000));
        assertEquals(VoiceCommands.Command.NONE,c.accept(result("lobo pausar captura",.89),4000));
        assertEquals(VoiceCommands.Command.NONE,c.accept("{\"text\":\"lobo\"}",6000));
        assertEquals(VoiceCommands.Command.NONE,c.accept(result("hola lobo",.6),8000));
    }
    @Test public void malformedAndMismatchReject() throws Exception {
        VoiceCommands c=new VoiceCommands();
        assertEquals(VoiceCommands.Command.NONE,c.accept("nonsense",2000));
        assertEquals(VoiceCommands.Command.NONE,c.accept(result("lobo pausar captura",1).replace("\"word\":\"lobo\"","\"word\":\"pausa\""),3000));
    }
    @Test public void repeatedActionsDebounceButDifferentActionsWork() throws Exception {
        VoiceCommands c=new VoiceCommands();
        assertEquals(VoiceCommands.Command.START,c.accept(result("lobo iniciar captura",1),2000));
        assertEquals(VoiceCommands.Command.NONE,c.accept(result("lobo iniciar captura",1),2200));
        assertEquals(VoiceCommands.Command.PAUSE,c.accept(result("lobo pausar captura",1),2500));
        assertEquals(VoiceCommands.Command.START,c.accept(result("lobo reanudar captura",1),3000));
    }
    @Test public void grammarCannotDropUnknownWakeWordOrContainIdleBareCommands() throws Exception {
        org.json.JSONArray g=new org.json.JSONArray(VoiceCommands.GRAMMAR);
        for(int i=0;i<g.length();i++) {String phrase=g.getString(i);assertTrue(phrase,phrase.equals("[unk]") || phrase.startsWith("lobo "));assertFalse(phrase.contains("lobot"));}
    }
}
