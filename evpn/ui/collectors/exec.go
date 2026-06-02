package collectors

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

var (
	httpClient     *http.Client
	httpClientOnce sync.Once
)

func getClient() *http.Client {
	httpClientOnce.Do(func() {
		socketPath := "/run/podman/podman.sock"
		httpClient = &http.Client{
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					return net.Dial("unix", socketPath)
				},
				MaxIdleConns:    10,
				IdleConnTimeout: 30 * time.Second,
			},
			Timeout: 0, // No timeout for streaming / long-running execs
		}
	})
	return httpClient
}

func podmanAPI(ctx context.Context, method, path string, body io.Reader) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, "http://localhost"+path, body)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return getClient().Do(req)
}

type apiContainer struct {
	ID     string            `json:"Id"`
	Names  []string          `json:"Names"`
	State  string            `json:"State"`
	Labels map[string]string `json:"Labels"`
}

func listContainersAPI(ctx context.Context) ([]apiContainer, error) {
	resp, err := podmanAPI(ctx, "GET", "/v1.47/containers/json?all=true", nil)
	if err != nil {
		return nil, fmt.Errorf("list containers: %w", err)
	}
	defer resp.Body.Close()

	var containers []apiContainer
	if err := json.NewDecoder(resp.Body).Decode(&containers); err != nil {
		return nil, fmt.Errorf("list containers decode: %w", err)
	}
	return containers, nil
}

type apiInspect struct {
	State struct {
		Status string `json:"Status"`
	} `json:"State"`
	NetworkSettings struct {
		Networks map[string]struct {
			IPAddress string `json:"IPAddress"`
		} `json:"Networks"`
	} `json:"NetworkSettings"`
}

func inspectContainerAPI(ctx context.Context, name string) (*apiInspect, error) {
	resp, err := podmanAPI(ctx, "GET", "/v1.47/containers/"+name+"/json", nil)
	if err != nil {
		return nil, fmt.Errorf("inspect %s: %w", name, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == 404 {
		return nil, nil
	}

	var insp apiInspect
	if err := json.NewDecoder(resp.Body).Decode(&insp); err != nil {
		return nil, fmt.Errorf("inspect decode %s: %w", name, err)
	}
	return &insp, nil
}

type execCreateRequest struct {
	Cmd          []string `json:"Cmd"`
	AttachStdout bool     `json:"AttachStdout"`
	AttachStderr bool     `json:"AttachStderr"`
}

type execCreateResponse struct {
	ID string `json:"Id"`
}

type execStartRequest struct {
	Detach bool `json:"Detach"`
	Tty    bool `json:"Tty"`
}

// ContainerExec executes a command on a container and returns stdout.
func ContainerExec(ctx context.Context, containerName string, cmd []string) ([]byte, error) {
	createBody, _ := json.Marshal(execCreateRequest{
		Cmd:          cmd,
		AttachStdout: true,
		AttachStderr: true,
	})

	resp, err := podmanAPI(ctx, "POST", "/v1.47/containers/"+containerName+"/exec", bytes.NewReader(createBody))
	if err != nil {
		return nil, fmt.Errorf("exec create %s: %w", containerName, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("exec create %s: HTTP %d: %s", containerName, resp.StatusCode, body)
	}

	var execResp execCreateResponse
	if err := json.NewDecoder(resp.Body).Decode(&execResp); err != nil {
		return nil, fmt.Errorf("exec create decode %s: %w", containerName, err)
	}

	startBody, _ := json.Marshal(execStartRequest{Detach: false, Tty: false})
	resp2, err := podmanAPI(ctx, "POST", "/v1.47/exec/"+execResp.ID+"/start", bytes.NewReader(startBody))
	if err != nil {
		return nil, fmt.Errorf("exec start %s: %w", containerName, err)
	}
	defer resp2.Body.Close()

	output, err := demuxStream(resp2.Body)
	if err != nil {
		return nil, fmt.Errorf("exec read %s: %w", containerName, err)
	}

	return output, nil
}

func demuxStream(reader io.Reader) ([]byte, error) {
	var stdout bytes.Buffer
	header := make([]byte, 8)
	for {
		_, err := io.ReadFull(reader, header)
		if err != nil {
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				break
			}
			return nil, err
		}
		size := int(header[4])<<24 | int(header[5])<<16 | int(header[6])<<8 | int(header[7])
		if size == 0 {
			continue
		}
		buf := make([]byte, size)
		_, err = io.ReadFull(reader, buf)
		if err != nil {
			return nil, err
		}
		if header[0] == 1 {
			stdout.Write(buf)
		}
	}
	return stdout.Bytes(), nil
}

// ContainerExecJSON executes a command and parses its output as JSON (cleans FRR garbage first).
func ContainerExecJSON(ctx context.Context, containerName string, cmd []string) ([]byte, error) {
	out, err := ContainerExec(ctx, containerName, cmd)
	if err != nil {
		return nil, err
	}

	return stripToJSON(out), nil
}

func stripToJSON(raw []byte) []byte {
	s := string(raw)
	idx := strings.Index(s, "{")
	if idx < 0 {
		idx = strings.Index(s, "[")
	}
	if idx < 0 {
		return raw
	}
	return []byte(s[idx:])
}

// ContainerExecStream executes a command and returns an io.ReadCloser streaming stdout.
func ContainerExecStream(ctx context.Context, containerName string, cmd []string) (io.ReadCloser, error) {
	createBody, _ := json.Marshal(execCreateRequest{
		Cmd:          cmd,
		AttachStdout: true,
		AttachStderr: true,
	})

	resp, err := podmanAPI(ctx, "POST", "/v1.47/containers/"+containerName+"/exec", bytes.NewReader(createBody))
	if err != nil {
		return nil, fmt.Errorf("exec create %s: %w", containerName, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("exec create %s: HTTP %d: %s", containerName, resp.StatusCode, body)
	}

	var execResp execCreateResponse
	if err := json.NewDecoder(resp.Body).Decode(&execResp); err != nil {
		return nil, fmt.Errorf("exec create decode %s: %w", containerName, err)
	}

	startBody, _ := json.Marshal(execStartRequest{Detach: false, Tty: false})
	resp2, err := podmanAPI(ctx, "POST", "/v1.47/exec/"+execResp.ID+"/start", bytes.NewReader(startBody))
	if err != nil {
		return nil, fmt.Errorf("exec start %s: %w", containerName, err)
	}

	// Return a custom ReadCloser that demuxes stream chunks on-the-fly!
	return &demuxReader{
		body:   resp2.Body,
		header: make([]byte, 8),
	}, nil
}

type demuxReader struct {
	body   io.ReadCloser
	header []byte
	left   int
}

func (d *demuxReader) Read(p []byte) (n int, err error) {
	if d.left > 0 {
		toRead := d.left
		if toRead > len(p) {
			toRead = len(p)
		}
		n, err = d.body.Read(p[:toRead])
		d.left -= n
		return n, err
	}

	for {
		_, err = io.ReadFull(d.body, d.header)
		if err != nil {
			return 0, err
		}
		size := int(d.header[4])<<24 | int(d.header[5])<<16 | int(d.header[6])<<8 | int(d.header[7])
		if size == 0 {
			continue
		}
		streamType := d.header[0]
		if streamType == 1 { // stdout
			d.left = size
			toRead := d.left
			if toRead > len(p) {
				toRead = len(p)
			}
			n, err = d.body.Read(p[:toRead])
			d.left -= n
			return n, err
		} else {
			// skip stderr or other streams
			discarded := 0
			buf := make([]byte, 512)
			for discarded < size {
				chunk := size - discarded
				if chunk > len(buf) {
					chunk = len(buf)
				}
				rn, err2 := d.body.Read(buf[:chunk])
				if err2 != nil {
					return 0, err2
				}
				discarded += rn
			}
		}
	}
}

func (d *demuxReader) Close() error {
	return d.body.Close()
}

// KubectlExec runs a kubectl command on a kind control plane.
func KubectlExec(ctx context.Context, node, kubeconfig string, kubectlArgs ...string) ([]byte, error) {
	args := []string{"kubectl"}
	if kubeconfig != "" {
		args = append(args, "--kubeconfig="+kubeconfig)
	}
	args = append(args, kubectlArgs...)
	return ContainerExec(ctx, node, args)
}

func splitStr(s string, sep string) []string {
	return strings.Split(s, sep)
}

func trimSpace(s string) string {
	return strings.TrimSpace(s)
}
