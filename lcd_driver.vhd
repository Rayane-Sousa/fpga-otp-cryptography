library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- -----------------------------------------------------------------------------
-- Module      : lcd_driver
-- Description : HD44780 16x2 Display Controller (4-bit interface).
--               Handles power-on initialization and byte-write requests.
-- Clock       : 50 MHz system clock (20 ns period)
-- -----------------------------------------------------------------------------
entity lcd_driver is
    port (
        sys_clk         : in  std_logic;                    
        sys_rst         : in  std_logic;                    
        char_data       : in  std_logic_vector(7 downto 0); 
        is_data_cmd     : in  std_logic;                    -- 0 = command, 1 = character
        send_trigger    : in  std_logic;                    -- Pulse high to transmit
        is_busy         : out std_logic;                    -- High when processing
        
        -- Physical LCD Pins
        lcd_rs_pin      : out std_logic;                    
        lcd_rw_pin      : out std_logic;                    
        lcd_en_pulse    : out std_logic;                    
        lcd_data_bus    : out std_logic_vector(7 downto 4)  
    );
end entity lcd_driver;

architecture rtl of lcd_driver is

    -- Timing specifications based on 50 MHz clk
    constant T_PWR_15MS  : natural := 750_000;  
    constant T_WAIT_4MS  : natural := 205_000;  
    constant T_WAIT_100U : natural :=   5_000;  
    constant T_CLR_2MS   : natural := 100_000;  
    constant T_CMD_50U   : natural :=   2_500;  
    constant T_EN_HIGH   : natural :=     100;  
    constant T_EN_LOW    : natural :=     100;  
    constant T_DATA_SET  : natural :=      20;  

    type lcd_fsm_t is (
        S_WAIT_PWR,
        S_WAKE1_SET, S_WAKE1_EN_H, S_WAKE1_EN_L, S_WAKE1_WAIT,
        S_WAKE2_SET, S_WAKE2_EN_H, S_WAKE2_EN_L, S_WAKE2_WAIT,
        S_WAKE3_SET, S_WAKE3_EN_H, S_WAKE3_EN_L, S_WAKE3_WAIT,
        S_MODE4_SET, S_MODE4_EN_H, S_MODE4_EN_L, S_MODE4_WAIT,
        S_CFG_HI_SET, S_CFG_HI_EN_H, S_CFG_HI_EN_L,
        S_CFG_LO_SET, S_CFG_LO_EN_H, S_CFG_LO_EN_L,
        S_CFG_WAIT,
        S_IDLE,
        S_TX_HI_SET, S_TX_HI_EN_H, S_TX_HI_EN_L,
        S_TX_LO_SET, S_TX_LO_EN_H, S_TX_LO_EN_L,
        S_TX_WAIT
    );

    type cfg_array_t is array (0 to 3) of std_logic_vector(7 downto 0);
    constant CFG_BYTES : cfg_array_t := (x"28", x"0C", x"01", x"06");

    signal current_state : lcd_fsm_t := S_WAIT_PWR;
    signal delay_cnt     : natural range 0 to T_PWR_15MS := 0;
    signal cfg_index     : integer range 0 to 3 := 0;

    signal target_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal target_rs     : std_logic := '0';

    -- Output buffers
    signal en_buf   : std_logic := '0';
    signal rs_buf   : std_logic := '0';
    signal db_buf   : std_logic_vector(7 downto 4) := (others => '0');
    signal busy_buf : std_logic := '1';

begin

    lcd_en_pulse <= en_buf;
    lcd_rs_pin   <= rs_buf;
    lcd_rw_pin   <= '0'; -- Write-only tied to ground
    lcd_data_bus <= db_buf;
    is_busy      <= busy_buf;

    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if sys_rst = '1' then
                current_state <= S_WAIT_PWR;
                delay_cnt     <= 0;
                cfg_index     <= 0;
                en_buf        <= '0';
                rs_buf        <= '0';
                db_buf        <= (others => '0');
                busy_buf      <= '1';
            else
                case current_state is
                    -- Power stabilization
                    when S_WAIT_PWR =>
                        busy_buf <= '1';
                        en_buf   <= '0';
                        if delay_cnt = T_PWR_15MS - 1 then
                            delay_cnt <= 0; current_state <= S_WAKE1_SET;
                        else delay_cnt <= delay_cnt + 1; end if;

                    -- First Wake-up Nibble (0x3)
                    when S_WAKE1_SET =>
                        rs_buf <= '0'; db_buf <= "0011";
                        if delay_cnt = T_DATA_SET - 1 then
                            delay_cnt <= 0; current_state <= S_WAKE1_EN_H;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_WAKE1_EN_H =>
                        en_buf <= '1';
                        if delay_cnt = T_EN_HIGH - 1 then
                            delay_cnt <= 0; en_buf <= '0'; current_state <= S_WAKE1_EN_L;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_WAKE1_EN_L =>
                        if delay_cnt = T_EN_LOW - 1 then
                            delay_cnt <= 0; current_state <= S_WAKE1_WAIT;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_WAKE1_WAIT =>
                        if delay_cnt = T_WAIT_4MS - 1 then
                            delay_cnt <= 0; current_state <= S_WAKE2_SET;
                        else delay_cnt <= delay_cnt + 1; end if;

                    -- Second Wake-up Nibble (0x3)
                    when S_WAKE2_SET =>
                        rs_buf <= '0'; db_buf <= "0011";
                        if delay_cnt = T_DATA_SET - 1 then
                            delay_cnt <= 0; current_state <= S_WAKE2_EN_H;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_WAKE2_EN_H =>
                        en_buf <= '1';
                        if delay_cnt = T_EN_HIGH - 1 then
                            delay_cnt <= 0; en_buf <= '0'; current_state <= S_WAKE2_EN_L;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_WAKE2_EN_L =>
                        if delay_cnt = T_EN_LOW - 1 then
                            delay_cnt <= 0; current_state <= S_WAKE2_WAIT;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_WAKE2_WAIT =>
                        if delay_cnt = T_WAIT_100U - 1 then
                            delay_cnt <= 0; current_state <= S_WAKE3_SET;
                        else delay_cnt <= delay_cnt + 1; end if;

                    -- Third Wake-up Nibble (0x3)
                    when S_WAKE3_SET =>
                        rs_buf <= '0'; db_buf <= "0011";
                        if delay_cnt = T_DATA_SET - 1 then
                            delay_cnt <= 0; current_state <= S_WAKE3_EN_H;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_WAKE3_EN_H =>
                        en_buf <= '1';
                        if delay_cnt = T_EN_HIGH - 1 then
                            delay_cnt <= 0; en_buf <= '0'; current_state <= S_WAKE3_EN_L;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_WAKE3_EN_L =>
                        if delay_cnt = T_EN_LOW - 1 then
                            delay_cnt <= 0; current_state <= S_WAKE3_WAIT;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_WAKE3_WAIT =>
                        if delay_cnt = T_WAIT_100U - 1 then
                            delay_cnt <= 0; current_state <= S_MODE4_SET;
                        else delay_cnt <= delay_cnt + 1; end if;

                    -- Enable 4-Bit Interface (0x2)
                    when S_MODE4_SET =>
                        rs_buf <= '0'; db_buf <= "0010";
                        if delay_cnt = T_DATA_SET - 1 then
                            delay_cnt <= 0; current_state <= S_MODE4_EN_H;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_MODE4_EN_H =>
                        en_buf <= '1';
                        if delay_cnt = T_EN_HIGH - 1 then
                            delay_cnt <= 0; en_buf <= '0'; current_state <= S_MODE4_EN_L;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_MODE4_EN_L =>
                        if delay_cnt = T_EN_LOW - 1 then
                            delay_cnt <= 0; current_state <= S_MODE4_WAIT;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_MODE4_WAIT =>
                        if delay_cnt = T_WAIT_100U - 1 then
                            delay_cnt     <= 0;
                            cfg_index     <= 0;
                            target_byte   <= CFG_BYTES(0);
                            target_rs     <= '0';
                            current_state <= S_CFG_HI_SET;
                        else delay_cnt <= delay_cnt + 1; end if;

                    -- Push Configuration Commands (High Nibble)
                    when S_CFG_HI_SET =>
                        rs_buf <= target_rs;
                        db_buf <= target_byte(7 downto 4);
                        if delay_cnt = T_DATA_SET - 1 then
                            delay_cnt <= 0; current_state <= S_CFG_HI_EN_H;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_CFG_HI_EN_H =>
                        en_buf <= '1';
                        if delay_cnt = T_EN_HIGH - 1 then
                            delay_cnt <= 0; en_buf <= '0'; current_state <= S_CFG_HI_EN_L;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_CFG_HI_EN_L =>
                        if delay_cnt = T_EN_LOW - 1 then
                            delay_cnt <= 0; current_state <= S_CFG_LO_SET;
                        else delay_cnt <= delay_cnt + 1; end if;

                    -- Push Configuration Commands (Low Nibble)
                    when S_CFG_LO_SET =>
                        rs_buf <= target_rs;
                        db_buf <= target_byte(3 downto 0);
                        if delay_cnt = T_DATA_SET - 1 then
                            delay_cnt <= 0; current_state <= S_CFG_LO_EN_H;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_CFG_LO_EN_H =>
                        en_buf <= '1';
                        if delay_cnt = T_EN_HIGH - 1 then
                            delay_cnt <= 0; en_buf <= '0'; current_state <= S_CFG_LO_EN_L;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_CFG_LO_EN_L =>
                        if delay_cnt = T_EN_LOW - 1 then
                            delay_cnt <= 0; current_state <= S_CFG_WAIT;
                        else delay_cnt <= delay_cnt + 1; end if;

                    -- Command Settling Time
                    when S_CFG_WAIT =>
                        if target_byte = x"01" then
                            if delay_cnt = T_CLR_2MS - 1 then
                                delay_cnt <= 0;
                                if cfg_index = 3 then
                                    current_state <= S_IDLE;
                                else
                                    cfg_index     <= cfg_index + 1;
                                    target_byte   <= CFG_BYTES(cfg_index + 1);
                                    current_state <= S_CFG_HI_SET;
                                end if;
                            else delay_cnt <= delay_cnt + 1; end if;
                        else
                            if delay_cnt = T_CMD_50U - 1 then
                                delay_cnt <= 0;
                                if cfg_index = 3 then
                                    current_state <= S_IDLE;
                                else
                                    cfg_index     <= cfg_index + 1;
                                    target_byte   <= CFG_BYTES(cfg_index + 1);
                                    current_state <= S_CFG_HI_SET;
                                end if;
                            else delay_cnt <= delay_cnt + 1; end if;
                        end if;

                    -- Idle / Ready for User Writes
                    when S_IDLE =>
                        busy_buf <= '0';
                        if send_trigger = '1' then
                            busy_buf      <= '1';
                            target_byte   <= char_data;
                            target_rs     <= is_data_cmd;
                            current_state <= S_TX_HI_SET;
                        end if;

                    -- Transmit User Byte (High Nibble)
                    when S_TX_HI_SET =>
                        rs_buf <= target_rs;
                        db_buf <= target_byte(7 downto 4);
                        if delay_cnt = T_DATA_SET - 1 then
                            delay_cnt <= 0; current_state <= S_TX_HI_EN_H;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_TX_HI_EN_H =>
                        en_buf <= '1';
                        if delay_cnt = T_EN_HIGH - 1 then
                            delay_cnt <= 0; en_buf <= '0'; current_state <= S_TX_HI_EN_L;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_TX_HI_EN_L =>
                        if delay_cnt = T_EN_LOW - 1 then
                            delay_cnt <= 0; current_state <= S_TX_LO_SET;
                        else delay_cnt <= delay_cnt + 1; end if;

                    -- Transmit User Byte (Low Nibble)
                    when S_TX_LO_SET =>
                        rs_buf <= target_rs;
                        db_buf <= target_byte(3 downto 0);
                        if delay_cnt = T_DATA_SET - 1 then
                            delay_cnt <= 0; current_state <= S_TX_LO_EN_H;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_TX_LO_EN_H =>
                        en_buf <= '1';
                        if delay_cnt = T_EN_HIGH - 1 then
                            delay_cnt <= 0; en_buf <= '0'; current_state <= S_TX_LO_EN_L;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when S_TX_LO_EN_L =>
                        if delay_cnt = T_EN_LOW - 1 then
                            delay_cnt <= 0; current_state <= S_TX_WAIT;
                        else delay_cnt <= delay_cnt + 1; end if;

                    -- Execution Delay
                    when S_TX_WAIT =>
                        if target_byte = x"01" or target_byte = x"02" then
                            if delay_cnt = T_CLR_2MS - 1 then
                                delay_cnt <= 0; current_state <= S_IDLE;
                            else delay_cnt <= delay_cnt + 1; end if;
                        else
                            if delay_cnt = T_CMD_50U - 1 then
                                delay_cnt <= 0; current_state <= S_IDLE;
                            else delay_cnt <= delay_cnt + 1; end if;
                        end if;

                    when others =>
                        current_state <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;