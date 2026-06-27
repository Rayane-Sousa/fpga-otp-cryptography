library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- -----------------------------------------------------------------------------
-- Module      : xor_engine
-- Description : Performs the core XOR operation for the One-Time Pad stream.
-- -----------------------------------------------------------------------------
entity xor_engine is
    Port (
        stream_in  : in  STD_LOGIC_VECTOR(7 downto 0);
        pad_key    : in  STD_LOGIC_VECTOR(7 downto 0);
        stream_out : out STD_LOGIC_VECTOR(7 downto 0)
    );
end xor_engine;

architecture rtl of xor_engine is
begin
    -- Simple bitwise XOR for both encryption and decryption
    stream_out <= stream_in xor pad_key;
end rtl;