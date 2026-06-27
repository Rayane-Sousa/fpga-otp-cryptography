library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- -----------------------------------------------------------------------------
-- Module      : kb_decoder
-- Description : Decodes PS/2 keyboard frames and converts Scan Set-2 to ASCII.
--               It reads the serial data from the keyboard, handles the protocol
--               (start, 8 data bits, parity, stop), and ignores key-release codes.
-- -----------------------------------------------------------------------------

entity kb_decoder is
    port (
        sys_clk    : in  std_logic;                     -- Main system clock
        sys_rst    : in  std_logic;                     -- Synchronous high-active reset
        kb_clk_pin : in  std_logic;                     -- Asynchronous clock from PS/2 keyboard (~10-16 kHz)
        kb_dat_pin : in  std_logic;                     -- Serial data from PS/2 keyboard
        char_out   : out std_logic_vector(7 downto 0);  -- Decoded ASCII character output
        is_valid   : out std_logic                      -- Pulses high for 1 clock cycle when char_out is valid
    );
end entity kb_decoder;

architecture rtl of kb_decoder is

    -- Shift register used to synchronize the asynchronous PS/2 clock to sys_clk
    -- and to detect the falling edge of the PS/2 clock reliably.
    signal clk_sync     : std_logic_vector(2 downto 0) := (others => '1');
    signal falling_edge : std_logic := '0';

    -- Shift register and state tracking for the incoming 11-bit PS/2 frame
    signal frame_idx    : integer range 0 to 11 := 0;   -- Tracks the current bit being received
    signal rx_shift_reg : std_logic_vector(10 downto 0) := (others => '0');
    signal byte_ready   : std_logic := '0';             -- Flag indicating a full 8-bit scan code was received
    signal raw_scancode : std_logic_vector(7 downto 0) := (others => '0');

    -- Signals for keyboard break code (key release) handling
    signal flag_break   : std_logic := '0';             -- Tracks if the previous byte was x"F0" (break code)
    signal reg_ascii    : std_logic_vector(7 downto 0) := (others => '0');
    signal reg_valid    : std_logic := '0';

    -- Function to map standard PS/2 Scan Code Set 2 to ASCII characters.
    -- Unmapped or unknown keys return x"00".
    function decode_scancode(sc : std_logic_vector(7 downto 0)) return std_logic_vector is
    begin
        case sc is
            -- Numbers 0-9
            when x"45" => return x"30"; when x"16" => return x"31";
            when x"1E" => return x"32"; when x"26" => return x"33";
            when x"25" => return x"34"; when x"2E" => return x"35";
            when x"36" => return x"36"; when x"3D" => return x"37";
            when x"3E" => return x"38"; when x"46" => return x"39";
            
            -- Letters A-Z
            when x"1C" => return x"41"; when x"32" => return x"42";
            when x"21" => return x"43"; when x"23" => return x"44";
            when x"24" => return x"45"; when x"2B" => return x"46";
            when x"34" => return x"47"; when x"33" => return x"48";
            when x"43" => return x"49"; when x"3B" => return x"4A";
            when x"42" => return x"4B"; when x"4B" => return x"4C";
            when x"3A" => return x"4D"; when x"31" => return x"4E";
            when x"44" => return x"4F"; when x"4D" => return x"50";
            when x"15" => return x"51"; when x"2D" => return x"52";
            when x"1B" => return x"53"; when x"2C" => return x"54";
            when x"3C" => return x"55"; when x"2A" => return x"56";
            when x"1D" => return x"57"; when x"22" => return x"58";
            when x"35" => return x"59"; when x"1A" => return x"5A";
            
            -- Special characters
            when x"5A" => return x"0D"; -- Enter (Carriage Return)
            when x"66" => return x"08"; -- Backspace
            when x"29" => return x"20"; -- Space
            when others => return x"00"; -- Unmapped key
        end case;
    end function decode_scancode;

begin

    -- -------------------------------------------------------------------------
    -- Clock Synchronization Process
    -- Prevents metastability by shifting the asynchronous PS/2 clock through 
    -- flip-flops clocked by the main system clock.
    -- -------------------------------------------------------------------------
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if sys_rst = '1' then
                clk_sync <= (others => '1');
            else
                -- Shift left: older values move to MSB, newest value enters at LSB
                clk_sync <= clk_sync(1 downto 0) & kb_clk_pin;
            end if;
        end if;
    end process;

    -- Detect a falling edge on the PS/2 clock:
    -- High if the previous state clk_sync(2) was '1' and the current state clk_sync(1) is '0'
    falling_edge <= clk_sync(2) and (not clk_sync(1));

    -- -------------------------------------------------------------------------
    -- Data Reception and Decoding Process
    -- -------------------------------------------------------------------------
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            -- Default assignments: these pulses are only high for one clock cycle
            byte_ready <= '0';
            reg_valid  <= '0';

            if sys_rst = '1' then
                frame_idx    <= 0;
                rx_shift_reg <= (others => '0');
                flag_break   <= '0';
                reg_ascii    <= (others => '0');
                raw_scancode <= (others => '0');
            else
                -- The PS/2 protocol specifies that data is valid on the falling edge of its clock
                if falling_edge = '1' then
                    if frame_idx = 0 then
                        -- State 0: Wait for start bit (should be '0')
                        rx_shift_reg <= (others => '0');
                        frame_idx    <= 1;
                    elsif frame_idx >= 1 and frame_idx <= 8 then
                        -- States 1-8: Shift in 8 data bits (LSB first)
                        rx_shift_reg <= kb_dat_pin & rx_shift_reg(10 downto 1);
                        frame_idx    <= frame_idx + 1;
                    elsif frame_idx = 9 then
                        -- State 9: Parity bit (ignored in this simple implementation)
                        frame_idx <= 10;
                    else
                        -- State 10: Stop bit (end of frame)
                        frame_idx    <= 0;
                        -- Extract the 8 data bits from the shift register
                        -- (Bits 10 downto 3 because of the way data was shifted in LSB first)
                        raw_scancode <= rx_shift_reg(10 downto 3); 
                        byte_ready   <= '1'; -- Signal that a full byte is ready to process
                    end if;
                end if;

                -- Process the fully received byte
                if byte_ready = '1' then
                    if raw_scancode = x"F0" then
                        -- x"F0" is the "Break" code, meaning a key was just released.
                        -- We set a flag to ignore the next incoming byte (the actual key code released).
                        flag_break <= '1';
                    elsif flag_break = '1' then
                        -- We just received the key code following the x"F0" break code.
                        -- We clear the flag and do nothing else (ignoring the release event).
                        flag_break <= '0';
                    else
                        -- This is a "Make" code (key pressed). 
                        -- Convert the raw PS/2 scancode to an ASCII character.
                        reg_ascii <= decode_scancode(raw_scancode);
                        
                        -- If the key is mapped in our decode function, validate the output
                        -- so the system knows a new key has been pressed.
                        if decode_scancode(raw_scancode) /= x"00" then
                            reg_valid <= '1';
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Route internal registers to external output ports
    char_out <= reg_ascii;
    is_valid <= reg_valid;

end architecture rtl;