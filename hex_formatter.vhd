library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- -----------------------------------------------------------------------------
-- Module      : hex_formatter
-- Description : Converts an 8-bit raw byte into two 8-bit ASCII hex characters.
--               For example, an input of x"3F" (00111111) will output:
--               char_hi = x"33" (ASCII '3') and char_lo = x"46" (ASCII 'F').
-- -----------------------------------------------------------------------------
entity hex_formatter is
    Port (
        raw_byte : in  STD_LOGIC_VECTOR(7 downto 0); -- The 8-bit input data to be converted
        char_hi  : out STD_LOGIC_VECTOR(7 downto 0); -- ASCII code for the Most Significant Nibble (upper 4 bits)
        char_lo  : out STD_LOGIC_VECTOR(7 downto 0)  -- ASCII code for the Least Significant Nibble (lower 4 bits)
    );
end hex_formatter;

architecture behavioral of hex_formatter is

    -- -------------------------------------------------------------------------
    -- Function    : encode_nibble
    -- Description : Maps a single 4-bit binary value (0x0 to 0xF) to its 
    --               corresponding 8-bit ASCII character representation 
    --               ('0'-'9' or 'A'-'F').
    -- -------------------------------------------------------------------------
    function encode_nibble(nibble : std_logic_vector(3 downto 0)) return std_logic_vector is
        variable ascii_val : std_logic_vector(7 downto 0);
    begin
        case nibble is
            -- Map hex digits 0-9 to ASCII characters '0'-'9' (x"30" to x"39")
            when "0000" => ascii_val := x"30"; when "0001" => ascii_val := x"31";
            when "0010" => ascii_val := x"32"; when "0011" => ascii_val := x"33";
            when "0100" => ascii_val := x"34"; when "0101" => ascii_val := x"35";
            when "0110" => ascii_val := x"36"; when "0111" => ascii_val := x"37";
            when "1000" => ascii_val := x"38"; when "1001" => ascii_val := x"39";
            
            -- Map hex digits A-F to ASCII characters 'A'-'F' (x"41" to x"46")
            when "1010" => ascii_val := x"41"; when "1011" => ascii_val := x"42";
            when "1100" => ascii_val := x"43"; when "1101" => ascii_val := x"44";
            when "1110" => ascii_val := x"45"; when others => ascii_val := x"46";
        end case;
        
        return ascii_val;
    end function;

begin
    
    -- -------------------------------------------------------------------------
    -- Concurrent Dataflow Assignments
    -- -------------------------------------------------------------------------
    
    -- Extract the upper 4 bits (bits 7 to 4), encode them, and assign to char_hi
    char_hi <= encode_nibble(raw_byte(7 downto 4));
    
    -- Extract the lower 4 bits (bits 3 to 0), encode them, and assign to char_lo
    char_lo <= encode_nibble(raw_byte(3 downto 0));

end behavioral;