package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/adrg/xdg"
	"github.com/google/uuid"
	getter "github.com/hashicorp/go-getter/v2"
	"github.com/hashicorp/nomad/jobspec2"
	"github.com/pkg/errors"
	"github.com/rs/zerolog"

	"github.com/input-output-hk/cicero/src/config"
	"github.com/input-output-hk/cicero/src/domain"
)

type EvaluationService interface {
	ListActions(src string) ([]string, error)
	EvaluateAction(src, name string, id uuid.UUID) (domain.ActionDefinition, error)
	EvaluateRun(src, name string, id uuid.UUID, inputs map[string]interface{}) (domain.RunDefinition, error)
}

func parseSource(src string) (fetchUrl *url.URL, evaluator string, err error) {
	fetchUrl, err = url.Parse(src)
	if err != nil {
		return
	}

	evaluator = fetchUrl.Fragment
	fetchUrl.Fragment = ""
	fetchUrl.RawFragment = ""

	return
}

type evaluationService struct {
	Evaluators   []string // Default evaluators. Will be tried in order if none is given for a source.
	Transformers []string
	logger       zerolog.Logger
}

func NewEvaluationService(evaluators, transformers []string, logger *zerolog.Logger) EvaluationService {
	return &evaluationService{
		Evaluators:   evaluators,
		Transformers: transformers,
		logger:       logger.With().Str("component", "EvaluationService").Logger(),
	}
}

// Evaluation failed due to a faulty action definition or transformer output.
type EvaluationError struct {
	err error
}

func (e EvaluationError) Error() string {
	return e.err.Error()
}

func (e EvaluationError) Unwrap() error {
	return e.err
}

func (e *evaluationService) evaluate(src string, args, extraEnv []string) ([]byte, error) {
	fetchUrl, evaluator, err := parseSource(src)
	if err != nil {
		return nil, err
	}

	cacheDir := config.GetenvStr("CICERO_CACHE_DIR")
	if cacheDir == "" {
		e.logger.Debug().Err(err).Msg("Falling back to XDG cache directory")
		cacheDir = xdg.CacheHome + "/cicero"
	}
	cacheDir += "/sources"

	dst, err := filepath.Abs(cacheDir + "/" + base64.RawURLEncoding.EncodeToString([]byte(src)))
	if err != nil {
		return nil, err
	}

	result, err := getter.GetAny(context.Background(), dst, fetchUrl.String())
	if err != nil {
		return nil, err
	}
	if result.Dst != dst {
		return nil, errors.WithMessage(err, "go-getter did not download to the given directory. This should never happen™")
	}

	tryEval := func(evaluator string) ([]byte, error) {
		cmd := exec.Command("cicero-evaluator-"+evaluator, args...)
		cmdEnv := append(extraEnv, "CICERO_ACTION_SRC="+dst) //nolint:gocritic // false positive
		cmd.Env = append(os.Environ(), cmdEnv...)            //nolint:gocritic // false positive

		e.logger.Debug().
			Strs("command", cmd.Args).
			Strs("environment", cmdEnv).
			Msg("Running evaluator")

		if output, err := cmd.Output(); err != nil {
			message := "Failed to evaluate"

			var errExit *exec.ExitError
			if errors.As(err, &errExit) {
				message += fmt.Sprintf("\nStdout: %s\nStderr: %s", output, errExit.Stderr)
				err = EvaluationError{err: errors.WithMessage(err, message)}
			}

			return nil, err
		} else {
			return output, err
		}
	}

	if evaluator != "" {
		if output, err := tryEval(evaluator); err != nil {
			return nil, errors.WithMessagef(err, "Evaluator %q specified in source failed", evaluator)
		} else {
			return output, nil
		}
	} else {
		e.logger.Debug().Msg("No evaluator given in source, trying all")
		var evalErr error
		for _, evaluator := range e.Evaluators {
			if output, err := tryEval(evaluator); err != nil {
				format := ""
				if evalErr != nil {
					format = "\n" + format
				}
				format += "Evaluator %q failed: %w"
				evalErr = fmt.Errorf(format, evaluator, err)
			} else {
				return output, nil
			}
		}
		e.logger.Err(evalErr).Msg("No evaluator succeeded.")
		return nil, errors.WithMessage(evalErr, "No evaluator succeeded.")
	}
}

func (e *evaluationService) EvaluateAction(src, name string, id uuid.UUID) (domain.ActionDefinition, error) {
	var def domain.ActionDefinition

	if output, err := e.evaluate(src,
		[]string{"eval", "meta", "inputs"},
		[]string{
			"CICERO_ACTION_NAME=" + name,
			"CICERO_ACTION_ID=" + id.String(),
		},
	); err != nil {
		return def, err
	} else if err := json.Unmarshal(output, &def); err != nil {
		e.logger.Err(err).Str("output", string(output)).Send()
		return def, errors.WithMessage(err, "While unmarshaling evaluator output")
	}

	return def, nil
}

func (e *evaluationService) EvaluateRun(src, name string, id uuid.UUID, inputs map[string]interface{}) (domain.RunDefinition, error) {
	var def domain.RunDefinition

	inputsJson, err := json.Marshal(inputs)
	if err != nil {
		return def, errors.WithMessagef(err, "Could not marshal inputs to JSON: %s", inputs)
	}

	extraEnv := []string{
		"CICERO_ACTION_NAME=" + name,
		"CICERO_ACTION_ID=" + id.String(),
		"CICERO_ACTION_INPUTS=" + string(inputsJson),
	}

	output, err := e.evaluate(src, []string{"eval", "output", "job"}, extraEnv)
	if err != nil {
		return def, err
	}

	output, err = e.transform(output, extraEnv)
	if err != nil {
		return def, err
	}

	freeformDef := struct {
		domain.RunDefinition
		Job *interface{} `json:"job"`
	}{}

	err = json.Unmarshal(output, &freeformDef)
	if err != nil {
		return def, errors.WithMessagef(err, "While unmarshaling evaluator output %s into freeform definition", string(output))
	}

	def.Output = freeformDef.Output
	if freeformDef.Job != nil {
		if job, err := json.Marshal(*freeformDef.Job); err != nil {
			return def, err
		} else {
			// escape HCL variable interpolation
			job = bytes.ReplaceAll(job, []byte("${"), []byte("$${"))

			if job, err := jobspec2.ParseWithConfig(&jobspec2.ParseConfig{
				Body:    []byte(`{"job":` + string(job) + "}"),
				AllowFS: false,
				Strict:  true,
			}); err != nil {
				return def, err
			} else {
				def.Job = job
			}
		}
	}

	return def, nil
}

func (e *evaluationService) transform(output []byte, extraEnv []string) ([]byte, error) {
	for _, transformer := range e.Transformers {
		cmd := exec.Command(transformer)
		cmd.Env = append(os.Environ(), extraEnv...) //nolint:gocritic // false positive

		stdin, err := cmd.StdinPipe()
		if err != nil {
			return nil, err
		}
		if _, err := io.Copy(stdin, bytes.NewReader(output)); err != nil {
			return nil, err
		}
		if err := stdin.Close(); err != nil {
			return nil, err
		}

		e.logger.Debug().
			Strs("command", cmd.Args).
			Strs("environment", extraEnv).
			Str("transformer", transformer).
			Msg("Running transformer")

		if transformedOutput, err := cmd.Output(); err != nil {
			message := "Failed to transform"

			var errExit *exec.ExitError
			if errors.As(err, &errExit) {
				message += fmt.Sprintf("\nStdout: %s\nStderr: %s", transformedOutput, errExit.Stderr)
				err = EvaluationError{err: errors.WithMessage(err, message)}
			}

			return nil, err
		} else {
			output = transformedOutput
		}
	}

	return output, nil
}

func (e *evaluationService) ListActions(src string) ([]string, error) {
	output, err := e.evaluate(src, []string{"list"}, nil)
	if err != nil {
		return nil, err
	}

	var names []string
	if err := json.Unmarshal(output, &names); err != nil {
		e.logger.Err(err).Str("output", string(output)).Msg("Could not unmarshal action names")
		return nil, errors.WithMessagef(err, "While unmarshaling action names:\n%s", string(output))
	}

	return names, nil
}
