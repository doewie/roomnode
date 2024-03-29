//  **********************************************************************************
//  Send the measurement of a RoomNode plug every hartbeat X multiplier ms.
//  f.i. : hartbeat = 1000, multiplier = 10 -> Data will be send every 10 seconds
//
//  Format incoming commands :
//
//  C ID Vl Vh Sync
//  |  |  |  |   |
//  |--|--|--|---|-- C(char) : CommandCode    'B'  : BlueLED on/off, value 1 = on, value 0 = off
//     |  |  |   |                            'K'  : Send KaKu command, value 1 = on, value 0 = off
//     |  |  |   |                            'H'  : Set hartbeat
//     |  |  |   |                            'L'  : Set the multiplier for the lux sensor
//     |  |  |   |                            'R'  : Set the multiplier for the relative hunidity sensor
//     |  |  |   |                            'T'  : Set the multiplier for the temperature
//     |  |  |   |                            'X'  : Reset the JeeNode, force watchdog timeout
//     |  |  |   |                            '*'  : Reset counterT, counterRH and counterLux
//     |  |  |   |                                    so all sensors will send 'immediately'
//     |  |  |   |                            '!'  : Bounce on Ping function from central application 
//     |  |  |   |                      
//     |--|--|---|-- ID(byte) : PortID          0  : This JeeNode
//        |  |   |                            1-4  : Sensor used port
//        |  |   |                             >4  : Future..
//        |--|---|-- Vl(byte) : value (Low Byte)
//           |---|-- Vh(byte) : value (High Byte)
//               |-- Sync(integer)                 : Sync counter generated by the central application                          
//
//  Format outgoing commands/acknowledgements :
//
//  SC C ID Vl Vh Sync
//  |  |  |  |  |   |
//  |--|--|--|--|---|-- SC(byte) : SensorCode      0   : none (JeeNode level)
//     |  |  |  |   |                              1   : temperature (Sensor level)
//     |  |  |  |   |                              2   : lux (Sensor level)
//     |  |  |  |   |                              3   : humidity (Sensor level)
//     |  |  |  |   |                              4   : pressure (Sensor level)
//     |  |  |  |   |                            100   : command acknowledgement
//     |--|--|--|---|-- C(char)  : Command Code  'D'   : Datavalue
//        |  |  |   |                            'S'   : Restart of the JeeNode
//        |  |  |   |                           xxxx   : Acknowledge incoming command *)
//        |--|--|---|-- ID(byte) : PortID          0   : This JeeNode
//           |  |   |                            1-4   : Sensor used port
//           |  |   |                             >4   : Future..
//           |--|---|-- Vl(byte) : value (Low Byte)
//              |---|-- Vh(byte) : value (High Byte)
//                  |-- Sync(integer)                  : Sync counter generated by the central application
//
//  *)
//  All incoming commands will be bounced back to central JeeLink + 100 in the SC byte 
//
//  Watchdog timer included, set at 8 seconds. Must be long otherwise
//  it will not be possible to reload new sketches.
//  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
//  BE CAREFULL : Re http://forum.jeelabs.net/node/449
//  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
//
//  Initial value for the hartbeat : 1000 ms / can be changed by command 'H'  to value
//
//
//  Initial values for the multipliers :
//  T : 2 sec // temperature every hartbeat * 2 seconds
//  RH : 4 sec // relative humidity every hartbeat * 4 seconds
//  LUX : 8 sec // lux every hartbeat * 8 seconds
//
//  set rf12_sendWait to IDLE = 1;
//  ***********************************************************************************  

#include <Ports.h>
#include <RF12.h>
#include <util/crc16.h>
#include <util/parity.h>
#include <avr/eeprom.h>
#include <avr/pgmspace.h>
#include <avr/wdt.h>
#include <PortsSHT11.h>
#include <String.h>

// constants ***************************************************************************

const char SKETCHNAME[] = "roomnode"; // name of the sketch
const char VERSION[] = "0011";        // version of the sketch

// initialvalues ***********************************************************************

int hartbeat = 1000; // basic heartbeat in ms
int multiplierT = 2; // wait multiplierT * hartbeat before sending next temperature value
int multiplierRH = 4;  // same for relative hunidity
int multiplierLux = 8; // same for lux
boolean showLed = true; // always start with blinking LED

uint32_t kakuHouseAddress = 4240854;
uint8_t  kakuGroup = 0; // select first group
uint8_t  kakuCode = 0;  // select first code


// type definitions ********************************************************************

typedef struct { 
    char commandCode; // commandCode
    byte portID;  // 0 for this JeeNode, 1..4 for specific ports, other values for future !! 
    int value; // use as control value in this test sketch
    int sync; // Sync value for central application
  } PayloadIn;

typedef struct {
    byte nodeCode; // 1 char
    char commandCode; // 1 char for type of value. f.i. 'D' = Data, 'S' = Start
    byte portID; // ID of the used port
    int value; // value 1 or 2 bytes
    int sync; // Sync value for the centralapplication
} PayloadOut;

// variables ***************************************************************************

PayloadIn inData;
PayloadOut outData;

int counterT = multiplierT;
int counterRH = multiplierRH;
int counterLux = multiplierLux;

// typeCounter used for selection of the unit to be send
byte typeCounter;
byte oldTypeCounter;
    
byte pendingOutput;
boolean outDataReady;

MilliTimer sendTimer;   // used to send at interval

// Port definitions *******************************************************************

Port radio (1);                                 // OOK433Plug in Port 1 of the JeeNode
Port ldr (2);
SHT11 sht11 (3);

// ********************************************************************

#define LED_PIN     9   // activity LED, comment out to disable

//static unsigned long now () {
//    // FIXME 49-day overflow
//    return millis() / 1000;
//}

static void activityLed (byte on) {
#ifdef LED_PIN
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, !on);
#endif
} 
static byte settingsBuffer[RF12_MAXDATA];

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
// RF12 configuration setup code

typedef struct {
    byte nodeId;
    byte group;
    char msg[RF12_EEPROM_SIZE-4];
    word crc;
} RF12Config;

static RF12Config config;

static char cmd;
static byte value, stack[RF12_MAXDATA], top, sendLen, dest, quiet;
static byte testbuf[RF12_MAXDATA], testCounter;

static void addCh (char* msg, char c) {
    byte n = strlen(msg);
    msg[n] = c;
}

static void addInt (char* msg, word v) {
    if (v >= 10)
        addInt(msg, v / 10);
    addCh(msg, '0' + v % 10);
}

static void saveConfig () {
    // set up a nice config string to be shown on startup
    memset(config.msg, 0, sizeof config.msg);
    strcpy(config.msg, " ");
    
    byte id = config.nodeId & 0x1F;
    addCh(config.msg, '@' + id);
    strcat(config.msg, " i");
    addInt(config.msg, id);
    
    strcat(config.msg, " g");
    addInt(config.msg, config.group);
    
    strcat(config.msg, " @ ");
    static word bands[4] = { 315, 433, 868, 915 };
    word band = config.nodeId >> 6;
    addInt(config.msg, bands[band]);
    strcat(config.msg, " MHz ");
    
    config.crc = ~0;
    for (byte i = 0; i < sizeof config - 2; ++i)
        config.crc = _crc16_update(config.crc, ((byte*) &config)[i]);

    // save to EEPROM
    for (byte i = 0; i < sizeof config; ++i) {
        byte b = ((byte*) &config)[i];
        eeprom_write_byte(RF12_EEPROM_ADDR + i, b);
    }
    
    if (!rf12_config())
        Serial.println("config save failed");
}

char helpText1[] PROGMEM = 
    "\n"
    "Available commands:" "\n"
    "  <nn> i     - set node ID (standard node ids are 1..26)" "\n"
    "               (or enter an uppercase 'A'..'Z' to set id)" "\n"
    "  <n> b      - set MHz band (4 = 433, 8 = 868, 9 = 915)" "\n"
    "  <nnn> g    - set network group (RFM12 only allows 212, 0 = any)" "\n"
    "  t          - broadcast max-size test packet, with ack" "\n"
    "  ...,<nn> a - send data packet to node <nn>, with ack" "\n"
    "  ...,<nn> s - send data packet to node <nn>, no ack" "\n"
    "  <n> l      - turn activity LED on PB1 on or off" "\n"
    "  <n> q      - set quiet mode (1 = don't report bad packets)" "\n"
;

static void showString (PGM_P s) {
    for (;;) {
        char c = pgm_read_byte(s++);
        if (c == 0)
            break;
        if (c == '\n')
            Serial.print('\r');
        Serial.print(c);
    }
}

static void showHelp () {
    showString(helpText1);
    Serial.println("Current configuration:");
    rf12_config();
}

static void handleInput (char c) {
    if ('0' <= c && c <= '9')
        value = 10 * value + c - '0';
    else if (c == ',') {
        if (top < sizeof stack)
            stack[top++] = value;
        value = 0;
    } else if ('a' <= c && c <='z') {
        Serial.print("> ");
        Serial.print((int) value);
        Serial.println(c);
        switch (c) {
            default:
                showHelp();
                break;
            case 'i': // set node id
                config.nodeId = (config.nodeId & 0xE0) + (value & 0x1F);
                saveConfig();
                break;
            case 'b': // set band: 4 = 433, 8 = 868, 9 = 915
                value = value == 8 ? RF12_868MHZ :
                        value == 9 ? RF12_915MHZ : RF12_433MHZ;
                config.nodeId = (value << 6) + (config.nodeId & 0x3F);
                saveConfig();
                break;
            case 'g': // set network group
                config.group = value;
                saveConfig();
                break;
            case 't': // broadcast a maximum size test packet, request an ack
                cmd = 'a';
                sendLen = RF12_MAXDATA;
                dest = 0;
                for (byte i = 0; i < RF12_MAXDATA; ++i)
                    testbuf[i] = i + testCounter;
                Serial.print("test ");
                Serial.println((int) testCounter); // first byte in test buffer
                ++testCounter;
                break;
            case 'a': // send packet to node ID N, request an ack
            case 's': // send packet to node ID N, no ack
                cmd = c;
                sendLen = top;
                dest = value;
                memcpy(testbuf, stack, top);
                break;
            case 'l': // turn activity LED on or off
                activityLed(value);
                break;
            case 'q': // turn quiet mode on or off (don't report bad packets)
                quiet = value;
                break;
        }
        value = top = 0;
        memset(stack, 0, sizeof stack);
    } else if ('A' <= c && c <= 'Z') {
        config.nodeId = (config.nodeId & 0xE0) + (c & 0x1F);
        saveConfig();
    } else if (c > ' ')
        showHelp();
}

// -------------------------------------------------------------------------------------------------

void waitForWatchdog() {
  do {
       // switch on activity led
        activityLed(1);
        delay(500);        
        // switch off activity led 
        activityLed(0);
        delay(500);
  } while (1);
}

// -------------------------------------------------------------------------------

// sendBit is used by the SendKaKuMessage
void sendBit(uint8_t bit)
{
  // Delays picked up from a "real life" capture from a remote control
  if (bit == 1)
  {
    // High bit
    delayMicroseconds(1180);
    radio.digiWrite(1);
    delayMicroseconds(360);
    radio.digiWrite(0);
    delayMicroseconds(184);
    radio.digiWrite(1);
    delayMicroseconds(348);
    radio.digiWrite(0);
  }
  else
  {
    // Low bit
    delayMicroseconds(188);
    radio.digiWrite(1);
    delayMicroseconds(352);
    radio.digiWrite(0);
    delayMicroseconds(1192);
    radio.digiWrite(1);
    delayMicroseconds(352);
    radio.digiWrite(0);
  }
}
// -----------------------------------------------------------------------

void sendKAKUMessage(uint32_t houseAddress, uint8_t group, uint8_t action, uint8_t code)
{
  // Send START/SYNC bits

  // dummy flip
  radio.digiWrite(0);
  delayMicroseconds(10044); // <-- Not sure if this is required, but the remote waits 
                            //     this amount of uSecs between the messages it sends, 
                            //     and you always need to send a message twice...
                            //     So I guess it's a good idea to use this number :-)
  radio.digiWrite(1);
  
  // START/SYNC
  delayMicroseconds(356);
  radio.digiWrite(0);
  delayMicroseconds(2544);
  radio.digiWrite(1);
  delayMicroseconds(364);
  radio.digiWrite(0);

  // Now send the house bits
  uint8_t bitCount;
  for (bitCount = 0; bitCount<26; bitCount++)
    sendBit( (houseAddress >> (25 - bitCount)) & 1 );
  
  // Group bit
  sendBit(group);
  
  // Action bit
  sendBit(action);
  
  // Code bits
  for (bitCount = 0; bitCount<4; bitCount++)
    sendBit( (code >> (3 - bitCount)) & 1 );
}

// -----------------------------------------------------------------------

static void consumeInData () {
  // save typeCounter before handling commandcode
   oldTypeCounter = typeCounter;
   typeCounter = 100; // >=100 used for command things
   
   // react on incoming command codes
   
   if (inData.commandCode == 'B') { // set blinking LED on/off
     showLed = inData.value; 
   }
   
   if (inData.commandCode == 'H') { // set hartbeat
      hartbeat = inData.value;
   }
   
   if (inData.commandCode == '*') { // reset counters
      counterT = 0;
      counterRH = 0;
      counterLux = 0;
   }
   
   if (inData.commandCode == 'T'){ // set multiplierT
      multiplierT = inData.value;
      counterT = 1; // set to 1 so start sending after 1 hartbeat cycle
   }
   
   if (inData.commandCode == 'R') { // set multiplierRH
      multiplierRH = inData.value;
      counterRH = 1;
   }
   
   if (inData.commandCode == 'L') { // set multiplierLux
      multiplierLux = inData.value;
      counterLux = 1;
   }
   
   if (inData.commandCode == 'X') {
      waitForWatchdog();
   }
   
   if (inData.commandCode == 'K') {
      
        // We NEED to send it at least twice, or it won't work!
        sendKAKUMessage(kakuHouseAddress, kakuGroup, inData.value, kakuCode);
        sendKAKUMessage(kakuHouseAddress, kakuGroup, inData.value, kakuCode); 
        sendKAKUMessage(kakuHouseAddress, kakuGroup, inData.value, kakuCode);
   }
   
}

// -------------------------------------------------------------------------

static byte produceOutData () {
  
  byte canSend = 0;
    
    if (counterT > 0){ counterT = counterT - 1; }
    if (counterRH > 0){ counterRH = counterRH - 1; }
    if (counterLux > 0){ counterLux = counterLux - 1; }
  
    if (typeCounter == 0){ // first start send START command 'S'
      // send Command 'S'
      outData.nodeCode = 0;
      outData.commandCode = 'S';
      outData.portID = 0;
      outData.value = 1;
      outData.sync = 0;
      canSend = 1;
    }
  
    if (typeCounter == 1 && counterT == 0){  // temperature
      // calc values from SHT11
        sht11.measure(SHT11::HUMI);        
        sht11.measure(SHT11::TEMP);
        float h, t;
        sht11.calculate(h, t);
        int humi = h + 0.5, temp = 10 * t + 0.5;
        
        // fill the output buffer
        outData.nodeCode = typeCounter;
        outData.commandCode = 'D';     // next part is data (D)
        outData.portID = 3;            // port nr.
        outData.value = temp;
        
        counterT = multiplierT;
        canSend = 1;
    }
    
    if (typeCounter == 2 && counterLux == 0) { // lux
       //calc value from LDR
        byte light = ~ ldr.anaRead() >> 2;
        
        // fill the output buffer
        outData.nodeCode = typeCounter;
        outData.commandCode = 'D';     // next part is data (D)
        outData.portID = 3;            // port nr.
        outData.value = light;
        
        counterLux = multiplierLux;
        canSend = 1;
    }
    
    if (typeCounter == 3 && counterRH == 0) { // humidity
     // calc values from SHT11
        sht11.measure(SHT11::HUMI);        
        sht11.measure(SHT11::TEMP);
        float h, t;
        sht11.calculate(h, t);
        int humi = h + 0.5, temp = 10 * t + 0.5;
        // fill the output buffer
        outData.nodeCode = typeCounter;
        outData.commandCode = 'D';     // next part is data (D)
        outData.portID = 3;            // port nr.
        outData.value = humi;
        
        counterRH = multiplierRH;
        canSend = 1;
    }
    
    if (typeCounter == 100) { // handle command
      outData.nodeCode = typeCounter;
      outData.commandCode = inData.commandCode;
      outData.portID = inData.portID;
      outData.value = inData.value;
      outData.sync = inData.sync;
      
      typeCounter = oldTypeCounter-1; // make sure next cycle sends good unit again
      canSend = 1;
    }
    
    // inc typeCounter to next unit
    typeCounter = typeCounter + 1;
    if (typeCounter == 4) {
      typeCounter = 1;
    }
     
    return canSend;
}

void setup() {
    Serial.begin(57600);
    Serial.print(SKETCHNAME);
    Serial.print("-");
    Serial.println(VERSION);
    //********************

    if (rf12_config()) {
        config.nodeId = eeprom_read_byte(RF12_EEPROM_ADDR);
        config.group = eeprom_read_byte(RF12_EEPROM_ADDR + 1);
    } else {
        config.nodeId = 0x41; // node A1 @ 433 MHz
        config.group = 0xD4;
        saveConfig();
    }
    
    ldr.digiWrite2(1);  // enable AIO pull-up
    
    radio.mode2(OUTPUT);
     
    typeCounter = 0; // start with Command 'S'
    
    showHelp();
    
    // make the JeeNode reboot if wdt_reset is not called
    // at least every 8 seconds
    wdt_enable(WDTO_8S);
   
}

void loop() {
    if (Serial.available())
        handleInput(Serial.read());
        
    // if data received, CRC = ok and datalength is inData length
    if (rf12_recvDone() && rf12_crc == 0 && rf12_len == sizeof inData) {
        memcpy(&inData, (byte*) rf12_data, sizeof inData);
        consumeInData();
    }
    
    // initialize datasend every hartbeat milliseconds
    if (sendTimer.poll(hartbeat)) {
        pendingOutput = produceOutData();
    }    
    
    if (pendingOutput && rf12_canSend()) {
       // switch on activity led
       if (showLed)
        activityLed(1);
        
        rf12_sendStart(0, &outData, sizeof outData);
        rf12_sendWait(1); // test !!!!
        pendingOutput = 0;
        
        // switch off activity led
        if (showLed)
        activityLed(0); 
    }
 
   wdt_reset(); // reset the watchdog timer   
 }
