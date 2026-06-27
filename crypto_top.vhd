library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- -----------------------------------------------------------------------------
-- Module      : crypto_top
-- Description : Top-level module interconnecting the KB decoder, LCD driver, 
--               XOR crypto engine, and Hex formatter. It orchestrates the 
--               entire system via a Finite State Machine (FSM).
-- -----------------------------------------------------------------------------
entity crypto_top is
    Port (
        sys_clk         : in  STD_LOGIC;                      -- Main system clock
        sys_rst         : in  STD_LOGIC;                      -- Main system reset
        kb_clk_pin      : in  STD_LOGIC;                      -- PS/2 Keyboard Clock
        kb_dat_pin      : in  STD_LOGIC;                      -- PS/2 Keyboard Data
        op_mode_sw      : in  STD_LOGIC;                      -- '0' = Encrypt, '1' = Decrypt
        status_leds     : out STD_LOGIC_VECTOR(2 downto 0);   -- LED indicators for FSM states
        lcd_rs_pin      : out STD_LOGIC;                      -- LCD Register Select (0=Cmd, 1=Data)
        lcd_rw_pin      : out STD_LOGIC;                      -- LCD Read/Write (usually tied low for write)
        lcd_en_pulse    : out STD_LOGIC;                      -- LCD Enable Pulse
        lcd_data_bus    : out STD_LOGIC_VECTOR(7 downto 4)    -- 4-bit LCD Data Bus
    );
end crypto_top;

architecture Behavioral of crypto_top is

    -- -------------------------------------------------------------------------
    -- System Constants
    -- -------------------------------------------------------------------------
    constant MAX_CHARS : integer := 16; -- Maximum characters per LCD line
    constant CHAR_CR   : std_logic_vector(7 downto 0) := x"0D"; -- Carriage Return (Enter)
    constant CHAR_BS   : std_logic_vector(7 downto 0) := x"08"; -- Backspace
    constant CHAR_SPC  : std_logic_vector(7 downto 0) := x"20"; -- Space

    -- Custom type for storing arrays of 16 bytes (used for passwords and messages)
    type memory_16B_t is array (0 to 15) of std_logic_vector(7 downto 0);
    
    -- Main System FSM States
    type sys_fsm_t is (
        STATE_BOOT, STATE_L1_CFG, STATE_L2_CFG, STATE_RX_PWD, 
        STATE_CLR_MSG, STATE_RX_MSG, STATE_DISP_L1, STATE_DISP_L2,
        STATE_HALT,
        -- Embedded LCD Helper FSM (Handles the low-level LCD protocol delays)
        STATE_LCD_CMD_SET, STATE_LCD_CMD_PULSE_H, STATE_LCD_CMD_PULSE_L, 
        STATE_LCD_DAT_SET, STATE_LCD_DAT_PULSE_H, STATE_LCD_DAT_PULSE_L
    );
    signal fsm_state    : sys_fsm_t := STATE_BOOT;
    signal resume_state : sys_fsm_t := STATE_BOOT; -- Tracks where to return after an LCD operation

    -- Memory buffers
    signal pwd_memory   : memory_16B_t := (others => CHAR_SPC);
    signal text_memory  : memory_16B_t := (others => CHAR_SPC);
    signal cipher_bus   : memory_16B_t;
    signal pwd_count    : integer range 0 to MAX_CHARS := 0;
    signal text_count   : integer range 0 to MAX_CHARS := 0;
    
    -- Variables used for unpacking hex characters into bytes during decryption mode
    signal hex_hi_cache : std_logic_vector(3 downto 0) := "0000";
    signal pending_nibble : std_logic := '0';

    -- Keyboard interface signals
    signal raw_ascii    : std_logic_vector(7 downto 0);
    signal kb_trigger   : std_logic;

    -- LCD driver interface signals
    signal lcd_reg_char : std_logic_vector(7 downto 0) := x"00";
    signal lcd_reg_rs   : std_logic := '0';
    signal lcd_reg_tx   : std_logic := '0';
    signal lcd_busy_flag: std_logic;

    -- Text buffer for LCD writing
    signal txt_buffer   : memory_16B_t := (others => CHAR_SPC);
    signal txt_len      : integer range 0 to 16 := 0;
    signal txt_idx      : integer range 0 to 15 := 0;
    signal req_command  : std_logic_vector(7 downto 0) := x"80";
    
    -- Formatting signals for Hex display
    signal format_hi    : memory_16B_t;
    signal format_lo    : memory_16B_t;
    signal source_mux   : memory_16B_t; 

    -- -------------------------------------------------------------------------
    -- Function: ascii_to_hex
    -- Converts an ASCII hex character ('0'-'9', 'A'-'F') back into a 4-bit value.
    -- -------------------------------------------------------------------------
    function ascii_to_hex(a : std_logic_vector(7 downto 0)) return std_logic_vector is
        variable val : unsigned(7 downto 0);
    begin
        val := unsigned(a);
        if val >= 48 and val <= 57 then return std_logic_vector(val(3 downto 0));
        elsif val >= 65 and val <= 70 then return std_logic_vector(val(3 downto 0) + to_unsigned(9, 4));
        else return "0000"; end if;
    end function;

begin

    -- -------------------------------------------------------------------------
    -- Sub-Module Instantiations
    -- -------------------------------------------------------------------------
    
    -- Keyboard Decoder
    u_decoder : entity work.kb_decoder
        port map (
            sys_clk => sys_clk, sys_rst => sys_rst, 
            kb_clk_pin => kb_clk_pin, kb_dat_pin => kb_dat_pin,
            char_out => raw_ascii, is_valid => kb_trigger
        );

    -- LCD Driver
    u_lcd_ctrl : entity work.lcd_driver
        port map (
            sys_clk => sys_clk, sys_rst => sys_rst, 
            char_data => lcd_reg_char, is_data_cmd => lcd_reg_rs,
            send_trigger => lcd_reg_tx, is_busy => lcd_busy_flag,
            lcd_rs_pin => lcd_rs_pin, lcd_rw_pin => lcd_rw_pin, 
            lcd_en_pulse => lcd_en_pulse, lcd_data_bus => lcd_data_bus
        );

    -- Instantiate 16 XOR engines (one for each character) to perform parallel cryptography
    gen_crypto: for i in 0 to MAX_CHARS-1 generate
        u_xor: entity work.xor_engine
            port map (stream_in => text_memory(i), pad_key => pwd_memory(i), stream_out => cipher_bus(i));
    end generate;
    
    -- Multiplexer to select what data gets fed to the Hex Formatter based on operation mode
    gen_mux: for i in 0 to 7 generate
        source_mux(i) <= cipher_bus(i) when op_mode_sw = '0' else text_memory(i);
    end generate;

    -- Instantiate Hex formatters for 8 bytes (which yields 16 hex chars for the LCD display)
    gen_formatter: for i in 0 to 7 generate
        u_format: entity work.hex_formatter
            port map (
                raw_byte => source_mux(i),
                char_hi => format_hi(i), char_lo => format_lo(i)
            );
    end generate;

    -- -------------------------------------------------------------------------
    -- Main Finite State Machine (System Controller)
    -- -------------------------------------------------------------------------
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if sys_rst = '1' then
                fsm_state <= STATE_BOOT;
                pwd_count <= 0; text_count <= 0; pending_nibble <= '0';
                pwd_memory <= (others => CHAR_SPC); text_memory <= (others => CHAR_SPC);
                lcd_reg_tx <= '0'; status_leds <= "000";
            else
                lcd_reg_tx <= '0'; 
                
                -- Global interrupt: Restart system if Enter is pressed while halted
                if kb_trigger = '1' and raw_ascii = CHAR_CR and fsm_state = STATE_HALT then
                    fsm_state <= STATE_BOOT;
                end if;

                case fsm_state is
                    -- Boot and system initialization
                    when STATE_BOOT =>
                        if lcd_busy_flag = '0' then
                            pwd_count <= 0; text_count <= 0; pending_nibble <= '0';
                            pwd_memory <= (others => CHAR_SPC); text_memory <= (others => CHAR_SPC);
                            status_leds <= "001";
                            req_command <= x"01"; -- LCD Clear Display Command
                            txt_len     <= 0;
                            resume_state<= STATE_L1_CFG;
                            fsm_state   <= STATE_LCD_CMD_SET;
                        end if;

                    -- Display initial UI on LCD Line 1 ("MODO: CRIPTO" or "MODO: DESCRI")
                    when STATE_L1_CFG =>
                        req_command <= x"80"; txt_len <= 16; -- x"80" sets cursor to Line 1, Col 1
                        txt_buffer(0) <= x"4D"; txt_buffer(1) <= x"4F"; txt_buffer(2) <= x"44"; txt_buffer(3) <= x"4F"; 
                        txt_buffer(4) <= x"3A"; txt_buffer(5) <= CHAR_SPC;
                        if op_mode_sw = '0' then
                            txt_buffer(6)<=x"43"; txt_buffer(7)<=x"52"; txt_buffer(8)<=x"49"; txt_buffer(9)<=x"50"; txt_buffer(10)<=x"54"; txt_buffer(11)<=x"4F";
                        else
                            txt_buffer(6)<=x"44"; txt_buffer(7)<=x"45"; txt_buffer(8)<=x"53"; txt_buffer(9)<=x"43"; txt_buffer(10)<=x"52"; txt_buffer(11)<=x"49";
                        end if;
                        txt_buffer(12)<=CHAR_SPC; txt_buffer(13)<=CHAR_SPC; txt_buffer(14)<=CHAR_SPC; txt_buffer(15)<=CHAR_SPC;
                        resume_state <= STATE_L2_CFG;
                        fsm_state    <= STATE_LCD_CMD_SET;

                    -- Display initial UI on LCD Line 2 ("SENHA:")
                    when STATE_L2_CFG =>
                        req_command <= x"C0"; txt_len <= 16; -- x"C0" sets cursor to Line 2, Col 1
                        txt_buffer(0)<=x"53"; txt_buffer(1)<=x"45"; txt_buffer(2)<=x"4E"; txt_buffer(3)<=x"48"; txt_buffer(4)<=x"41"; txt_buffer(5)<=x"3A"; txt_buffer(6)<=CHAR_SPC; 
                        txt_buffer(7)<=CHAR_SPC; txt_buffer(8)<=CHAR_SPC; txt_buffer(9)<=CHAR_SPC; txt_buffer(10)<=CHAR_SPC; txt_buffer(11)<=CHAR_SPC; txt_buffer(12)<=CHAR_SPC; txt_buffer(13)<=CHAR_SPC; txt_buffer(14)<=CHAR_SPC; txt_buffer(15)<=CHAR_SPC;
                        resume_state <= STATE_RX_PWD;
                        fsm_state    <= STATE_LCD_CMD_SET;

                    -- Receive Password loop
                    when STATE_RX_PWD =>
                        if kb_trigger = '1' then
                            if raw_ascii = CHAR_CR then
                                -- Enter pressed, move to next step
                                fsm_state <= STATE_CLR_MSG;
                            elsif raw_ascii = CHAR_BS and pwd_count > 0 then
                                -- Backspace handling
                                pwd_count <= pwd_count - 1;
                                req_command <= std_logic_vector(to_unsigned(192 + 6 + pwd_count - 1, 8));
                                txt_len <= 1; txt_buffer(0) <= CHAR_SPC;
                                resume_state <= STATE_RX_PWD; fsm_state <= STATE_LCD_CMD_SET;
                            elsif pwd_count < MAX_CHARS and raw_ascii >= x"20" and raw_ascii <= x"7E" then
                                -- Store valid ASCII character and echo to display
                                pwd_memory(pwd_count) <= raw_ascii;
                                req_command <= std_logic_vector(to_unsigned(192 + 6 + pwd_count, 8));
                                txt_len <= 1; txt_buffer(0) <= raw_ascii;
                                pwd_count <= pwd_count + 1;
                                resume_state <= STATE_RX_PWD; fsm_state <= STATE_LCD_CMD_SET;
                            end if;
                        end if;

                    -- Clear the LCD to start receiving the message
                    when STATE_CLR_MSG =>
                        status_leds <= "010";
                        req_command <= x"01"; txt_len <= 0;
                        resume_state <= STATE_RX_MSG;
                        fsm_state <= STATE_LCD_CMD_SET;

                    -- Receive the Message (Text or Ciphertext)
                    when STATE_RX_MSG =>
                        if kb_trigger = '1' then
                            if raw_ascii = CHAR_CR then
                                -- Enter pressed, process message
                                fsm_state <= STATE_DISP_L1;
                            elsif raw_ascii = CHAR_BS then
                                -- Complex Backspace handling depending on Encrypt or Decrypt mode
                                if op_mode_sw = '1' then -- Decrypt Mode
                                    if pending_nibble = '1' then
                                        pending_nibble <= '0';
                                        req_command <= std_logic_vector(to_unsigned(128 + (text_count * 2), 8));
                                        txt_len <= 1; txt_buffer(0) <= CHAR_SPC;
                                        resume_state <= STATE_RX_MSG; fsm_state <= STATE_LCD_CMD_SET;
                                    elsif text_count > 0 then
                                        text_count <= text_count - 1;
                                        req_command <= std_logic_vector(to_unsigned(128 + (text_count - 1) * 2, 8));
                                        txt_len <= 2; txt_buffer(0) <= CHAR_SPC; txt_buffer(1) <= CHAR_SPC;
                                        resume_state <= STATE_RX_MSG; fsm_state <= STATE_LCD_CMD_SET;
                                    end if;
                                elsif text_count > 0 then -- Encrypt Mode
                                    text_count <= text_count - 1;
                                    req_command <= std_logic_vector(to_unsigned(128 + text_count - 1, 8));
                                    txt_len <= 1; txt_buffer(0) <= CHAR_SPC;
                                    resume_state <= STATE_RX_MSG; fsm_state <= STATE_LCD_CMD_SET;
                                end if;
                            else
                                -- Read character based on current mode
                                if op_mode_sw = '0' then
                                    -- Encrypt Mode: Standard ASCII Input
                                    if text_count < MAX_CHARS and raw_ascii >= x"20" and raw_ascii <= x"7E" then
                                        text_memory(text_count) <= raw_ascii;
                                        req_command <= std_logic_vector(to_unsigned(128 + text_count, 8));
                                        txt_len <= 1; txt_buffer(0) <= raw_ascii;
                                        text_count <= text_count + 1;
                                        resume_state <= STATE_RX_MSG; fsm_state <= STATE_LCD_CMD_SET;
                                    end if;
                                else
                                    -- Decrypt Mode: Hexadecimal Input.
                                    -- Combines two ASCII hex characters into a single byte.
                                    if text_count < (MAX_CHARS / 2) and ((raw_ascii >= x"30" and raw_ascii <= x"39") or (raw_ascii >= x"41" and raw_ascii <= x"46")) then
                                        if pending_nibble = '0' then
                                            -- First nibble received
                                            hex_hi_cache <= ascii_to_hex(raw_ascii);
                                            pending_nibble <= '1';
                                            req_command <= std_logic_vector(to_unsigned(128 + (text_count * 2), 8));
                                        else
                                            -- Second nibble received: combine and save byte
                                            text_memory(text_count) <= hex_hi_cache & ascii_to_hex(raw_ascii);
                                            text_count <= text_count + 1;
                                            pending_nibble <= '0';
                                            req_command <= std_logic_vector(to_unsigned(128 + (text_count * 2) + 1, 8));
                                        end if;
                                        
                                        txt_len <= 1; txt_buffer(0) <= raw_ascii;
                                        resume_state <= STATE_RX_MSG; fsm_state <= STATE_LCD_CMD_SET;
                                    end if;
                                end if;
                            end if;
                        end if;

                    -- Display the result on Line 1 (Plain text / Decrypted text)
                    when STATE_DISP_L1 =>
                        status_leds <= "100";
                        req_command <= x"80"; txt_len <= 16;
                        for i in 0 to 15 loop
                            if i < text_count then
                                if op_mode_sw = '0' then txt_buffer(i) <= text_memory(i); else txt_buffer(i) <= cipher_bus(i); end if;
                            else txt_buffer(i) <= CHAR_SPC; end if;
                        end loop;
                        resume_state <= STATE_DISP_L2;
                        fsm_state    <= STATE_LCD_CMD_SET;
                        
                    -- Display the result on Line 2 (Cipher text / Encrypted Hex)
                    when STATE_DISP_L2 =>
                        req_command <= x"C0"; txt_len <= 16;
                        for i in 0 to 7 loop
                            txt_buffer(i*2)     <= format_hi(i);
                            txt_buffer(i*2 + 1) <= format_lo(i);
                        end loop;
                        resume_state <= STATE_HALT;
                        fsm_state    <= STATE_LCD_CMD_SET;

                    -- Idle state, wait for user to press Enter to reboot
                    when STATE_HALT =>
                        null;

                    -- ---------------------------------------------------------
                    -- Embedded LCD Protocol Helper FSM
                    -- This section iterates through txt_buffer, handling the 
                    -- Enable pulses required by the LCD controller IC.
                    -- ---------------------------------------------------------
                    when STATE_LCD_CMD_SET =>
                        if lcd_busy_flag = '0' then
                            lcd_reg_char <= req_command; lcd_reg_rs <= '0'; lcd_reg_tx <= '1';
                            txt_idx <= 0; fsm_state <= STATE_LCD_CMD_PULSE_H;
                        end if;
                    when STATE_LCD_CMD_PULSE_H =>
                        lcd_reg_tx <= '0'; if lcd_busy_flag = '1' then fsm_state <= STATE_LCD_CMD_PULSE_L; end if;
                    when STATE_LCD_CMD_PULSE_L =>
                        if lcd_busy_flag = '0' then
                            if txt_len > 0 then fsm_state <= STATE_LCD_DAT_SET; else fsm_state <= resume_state; end if;
                        end if;
                    when STATE_LCD_DAT_SET =>
                        if lcd_busy_flag = '0' then
                            lcd_reg_char <= txt_buffer(txt_idx); lcd_reg_rs <= '1'; lcd_reg_tx <= '1';
                            fsm_state <= STATE_LCD_DAT_PULSE_H;
                        end if;
                    when STATE_LCD_DAT_PULSE_H =>
                        lcd_reg_tx <= '0'; if lcd_busy_flag = '1' then fsm_state <= STATE_LCD_DAT_PULSE_L; end if;
                    when STATE_LCD_DAT_PULSE_L =>
                        if lcd_busy_flag = '0' then
                            if txt_idx = txt_len - 1 then fsm_state <= resume_state;
                            else txt_idx <= txt_idx + 1; fsm_state <= STATE_LCD_DAT_SET; end if;
                        end if;

                    -- Fallback
                    when others => fsm_state <= STATE_BOOT;
                end case;
            end if;
        end if;
    end process;
end Behavioral;