package mail

import (
	"crypto/tls"
	"fmt"
	"log"
	"mime"
	"net"
	"net/smtp"
	"strings"
	"time"
)

type Mailer interface {
	Send(to, subject, body string) error
}

// Log is the development fallback when no SMTP server is configured.
type Log struct{}

func (Log) Send(to, subject, body string) error {
	log.Printf("MAIL an %s: %s\n%s", to, subject, body)
	return nil
}

type SMTP struct {
	Host, Port, User, Pass, From string
}

func (m *SMTP) Send(to, subject, body string) error {
	addr := net.JoinHostPort(m.Host, m.Port)
	dialer := &net.Dialer{Timeout: 15 * time.Second}
	var conn net.Conn
	var err error
	if m.Port == "465" {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{ServerName: m.Host})
	} else {
		conn, err = dialer.Dial("tcp", addr)
	}
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(30 * time.Second))

	client, err := smtp.NewClient(conn, m.Host)
	if err != nil {
		return err
	}
	defer client.Close()
	if ok, _ := client.Extension("STARTTLS"); ok {
		if err := client.StartTLS(&tls.Config{ServerName: m.Host}); err != nil {
			return err
		}
	}
	if m.User != "" {
		// PlainAuth refuses to send credentials over an unencrypted remote connection.
		if err := client.Auth(smtp.PlainAuth("", m.User, m.Pass, m.Host)); err != nil {
			return err
		}
	}
	if err := client.Mail(m.From); err != nil {
		return err
	}
	if err := client.Rcpt(to); err != nil {
		return err
	}
	w, err := client.Data()
	if err != nil {
		return err
	}
	var msg strings.Builder
	fmt.Fprintf(&msg, "From: %s\r\n", m.From)
	fmt.Fprintf(&msg, "To: %s\r\n", to)
	fmt.Fprintf(&msg, "Subject: %s\r\n", mime.QEncoding.Encode("utf-8", subject))
	fmt.Fprintf(&msg, "Date: %s\r\n", time.Now().Format(time.RFC1123Z))
	msg.WriteString("MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n")
	msg.WriteString(strings.ReplaceAll(body, "\n", "\r\n"))
	if _, err := w.Write([]byte(msg.String())); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return client.Quit()
}
