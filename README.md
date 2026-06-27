<div align="center">

# 🔐 One-Time Pad Crypto Engine (FPGA)

[![FPGA](https://img.shields.io/badge/FPGA-Spartan--3A-blue.svg?style=flat-square)](https://www.xilinx.com/products/silicon-devices/fpga/spartan-3a.html)
[![Language](https://img.shields.io/badge/VHDL-IEEE--1164-orange.svg?style=flat-square)](https://standards.ieee.org/)
[![IDE](https://img.shields.io/badge/Xilinx-ISE_Design_Suite-red.svg?style=flat-square)](https://www.xilinx.com/)

*A hardware-accelerated cryptographic system utilizing the unbreakable One-Time Pad (OTP) cipher, implemented entirely in VHDL for the Xilinx Spartan-3A FPGA.*

[Features](#-key-features) • [Hardware Architecture](#-hardware-architecture) • [Getting Started](#-getting-started) • [System Flow](#-system-flow)

</div>

---

## 📝 Overview

This project implements a standalone, fully interactive cryptographic device on an FPGA. It allows users to input data via a standard **PS/2 keyboard**, processes the data through a fully parallel **XOR cryptographic engine**, and outputs the results in real-time on an **HD44780 16x2 Character LCD**.

Relying on the **One-Time Pad (OTP)** concept, this hardware engine is mathematically unbreakable as long as the key (password) is random, kept secret, and never reused.

## ✨ Key Features

* **Dual-Mode Operation**: Seamlessly switch between Encryption (Plaintext → Hex Ciphertext) and Decryption (Hex Ciphertext → Plaintext) using a physical hardware switch.
* **Hardware-Accelerated Parallelism**: Instantiates 16 independent XOR engines capable of encrypting/decrypting a 16-character block simultaneously in a single clock cycle.
* **Custom PS/2 Controller**: Robust asynchronous clock synchronization, 11-bit serial frame decoding, and smart mapping of Scan Code Set-2 to ASCII (including `Break` code handling).
* **On-the-Fly Hexadecimal Formatting**: Automatically packs/unpacks 8-bit bytes into/from human-readable ASCII hex characters for LCD presentation.
* **Embedded UI Engine**: A robust Finite State Machine (FSM) orchestrates the LCD delays and handles complex user inputs (like `Backspace` corrections across different hex nibbles).

## 🧰 Hardware Architecture

The system is highly modular, driven by the `crypto_top` entity which acts as the FSM master.

```mermaid
graph TD
    A[PS/2 Keyboard] -->|Serial Data/Clk| B(KB Decoder)
    B -->|Raw ASCII| C{Main FSM <br> crypto_top}
    SW[Mode Switch] -->|0: Encrypt / 1: Decrypt| C
    
    C <-->|Buffer 16B| D[XOR Crypto Array <br> x16 Parallel Engines]
    C -->|Raw Byte| E[Hex Formatter]
    E -->|ASCII Hi/Lo| C
    
    C -->|Control/Data Bus| F(LCD Driver)
    F -->|4-bit Data / RS / EN| G[HD44780 LCD]
