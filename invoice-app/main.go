package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"

	"pleo.io/invoice-app/db"

	"github.com/gin-gonic/gin"
)

var dbClient *db.Client
var paymentProviderURL string

func main() {
	dbClient = db.InitializeDatabase()

	paymentProviderURL = os.Getenv("PAYMENT_PROVIDER_URL")
	if paymentProviderURL == "" {
		paymentProviderURL = "http://payment-provider:8082/payments/pay"
	}

	router := setupRouter()

	err := router.Run(":8081")
	if err != nil {
		fmt.Printf("could not start server: %v", err)
	}
}

func setupRouter() *gin.Engine {
	r := gin.New()
	r.GET("/healthz", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	r.POST("invoices/pay", pay)
	r.GET("invoices", getInvoices)
	return r
}

func getInvoices(c *gin.Context) {
	invoices := dbClient.GetInvoices()

	c.JSON(http.StatusOK, invoices)
}

func pay(c *gin.Context) {
	invoices := dbClient.GetUnpaidInvoices()
	for _, invoice := range invoices {
		client := http.Client{}
		req := payRequest{
			Id:       invoice.InvoiceId,
			Value:    invoice.Value,
			Currency: invoice.Currency,
		}
		b, err := json.Marshal(req)
		data := bytes.NewBuffer(b)
		_, err = client.Post(paymentProviderURL, "application/json", data)

		if err != nil {
			fmt.Printf("Error %s", err)
			return
		}

		dbClient.PayInvoice(invoice.InvoiceId)
	}

	fmt.Printf("Invoices paid!\n")

	c.JSON(http.StatusOK, gin.H{})
}

type payRequest struct {
	Id       string  `json:"id"`
	Value    float32 `json:"value"`
	Currency string  `json:"currency"`
}
