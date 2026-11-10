package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// partSize keeps what an upload of unknown length holds in memory small.
const partSize = 5 << 20

// S3Config describes a bucket of any S3-compatible service.
type S3Config struct {
	// Endpoint like https://s3.eu-central-1.amazonaws.com or http://localhost:9000.
	Endpoint string
	Region   string
	Bucket   string
	// Prefix goes in front of every key, for several installations in one bucket.
	Prefix string
	// Without keys the credentials come from the role of the machine.
	AccessKey string
	SecretKey string
	// PathStyle puts the bucket in the path, for services without bucket subdomains.
	PathStyle bool
	// CreateBucket makes a missing bucket, for a service set up only for this.
	CreateBucket bool
}

// S3 keeps files in a bucket.
type S3 struct {
	client *minio.Client
	bucket string
	prefix string
}

// NewS3 connects and checks the bucket, so that a wrong setting shows at the start
// rather than with the first upload.
func NewS3(ctx context.Context, cfg S3Config) (*S3, error) {
	if cfg.Bucket == "" {
		return nil, errors.New("S3_BUCKET fehlt")
	}
	endpoint := cfg.Endpoint
	if endpoint == "" {
		endpoint = "https://s3.amazonaws.com"
	}
	address, err := url.Parse(endpoint)
	if err != nil || address.Host == "" || (address.Scheme != "http" && address.Scheme != "https") {
		return nil, fmt.Errorf("S3_ENDPOINT %q ist keine Adresse mit http:// oder https://", endpoint)
	}
	creds := credentials.NewIAM("")
	if cfg.AccessKey != "" {
		creds = credentials.NewStaticV4(cfg.AccessKey, cfg.SecretKey, "")
	}
	lookup := minio.BucketLookupAuto
	if cfg.PathStyle {
		lookup = minio.BucketLookupPath
	}
	client, err := minio.New(address.Host, &minio.Options{
		Creds:        creds,
		Secure:       address.Scheme == "https",
		Region:       cfg.Region,
		BucketLookup: lookup,
	})
	if err != nil {
		return nil, err
	}
	exists, err := client.BucketExists(ctx, cfg.Bucket)
	if err != nil {
		return nil, fmt.Errorf("Bucket %q: %w", cfg.Bucket, err)
	}
	if !exists && cfg.CreateBucket {
		if err := client.MakeBucket(ctx, cfg.Bucket, minio.MakeBucketOptions{Region: cfg.Region}); err != nil {
			return nil, fmt.Errorf("Bucket %q anlegen: %w", cfg.Bucket, err)
		}
		exists = true
	}
	if !exists {
		return nil, fmt.Errorf("Bucket %q gibt es nicht", cfg.Bucket)
	}
	prefix := strings.Trim(cfg.Prefix, "/")
	if prefix != "" {
		prefix += "/"
	}
	return &S3{client: client, bucket: cfg.Bucket, prefix: prefix}, nil
}

// failedReader remembers why reading stopped, which the client may wrap beyond
// recognition, while the caller needs to tell a file that is too big from an outage.
type failedReader struct {
	io.Reader
	err error
}

func (r *failedReader) Read(p []byte) (int, error) {
	n, err := r.Reader.Read(p)
	if err != nil && !errors.Is(err, io.EOF) {
		r.err = err
	}
	return n, err
}

func (s *S3) Put(ctx context.Context, key string, content io.Reader, contentType string) (int64, error) {
	reader := &failedReader{Reader: content}
	info, err := s.client.PutObject(ctx, s.bucket, s.prefix+key, reader, -1, minio.PutObjectOptions{
		ContentType: contentType,
		PartSize:    partSize,
	})
	if reader.err != nil {
		return 0, reader.err
	}
	if err != nil {
		return 0, err
	}
	return info.Size, nil
}

func (s *S3) Get(ctx context.Context, key string) (io.ReadCloser, int64, error) {
	object, err := s.client.GetObject(ctx, s.bucket, s.prefix+key, minio.GetObjectOptions{})
	if err != nil {
		return nil, 0, err
	}
	// Only asking for the details reaches the service.
	info, err := object.Stat()
	if err != nil {
		object.Close()
		if minio.ToErrorResponse(err).Code == "NoSuchKey" {
			return nil, 0, ErrNotFound
		}
		return nil, 0, err
	}
	return object, info.Size, nil
}

func (s *S3) Delete(ctx context.Context, key string) error {
	return s.client.RemoveObject(ctx, s.bucket, s.prefix+key, minio.RemoveObjectOptions{})
}
