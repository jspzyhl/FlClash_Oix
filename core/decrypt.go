package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"errors"
)

func DecryptFlClash(data []byte) ([]byte, error) {
	if len(data) < 4+1+12+16 {
		return nil, errors.New("invalid encrypted structure size")
	}
	if string(data[:4]) != "FLEN" || data[4] != 0x02 {
		return nil, errors.New("magic or version mismatch")
	}
	iv := data[5 : 5+12]
	ciphertext := data[5+12:]

	keyStr := GlobalProfileKey
	if keyStr == "" {
		return nil, errors.New("profile key is not injected")
	}
	hash := sha256.Sum256([]byte(keyStr))

	block, err := aes.NewCipher(hash[:])
	if err != nil {
		return nil, err
	}
	aesgcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	plaintext, err := aesgcm.Open(nil, iv, ciphertext, nil)
	if err != nil {
		return nil, err
	}

	var filtered []byte
	for i := 0; i < len(plaintext); i++ {
		if plaintext[i] < 32 && plaintext[i] != '\n' && plaintext[i] != '\r' && plaintext[i] != '\t' {
			return nil, errors.New("invalid character found in decrypted text")
		}
		filtered = append(filtered, plaintext[i])
	}

	return filtered, nil
}
