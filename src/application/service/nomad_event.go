package service

import (
	"encoding/json"

	"github.com/google/uuid"
	nomad "github.com/hashicorp/nomad/api"
	"github.com/pkg/errors"
	"github.com/rs/zerolog"

	"github.com/input-output-hk/cicero/src/config"
	"github.com/input-output-hk/cicero/src/domain"
	"github.com/input-output-hk/cicero/src/domain/repository"
	"github.com/input-output-hk/cicero/src/infrastructure/persistence"
)

type NomadEventService interface {
	WithQuerier(config.PgxIface) NomadEventService

	Save(*nomad.Event) error
	GetLastNomadEvent() (uint64, error)
	GetEventAllocByNomadJobId(id uuid.UUID) (map[string]domain.AllocWrapper, error)
}

type nomadEventService struct {
	logger               zerolog.Logger
	nomadEventRepository repository.NomadEventRepository
	runService           RunService
}

func NewNomadEventService(db config.PgxIface, runService RunService, logger *zerolog.Logger) NomadEventService {
	return &nomadEventService{
		logger:               logger.With().Str("component", "NomadEventService").Logger(),
		nomadEventRepository: persistence.NewNomadEventRepository(db),
		runService:           runService,
	}
}

func (n *nomadEventService) WithQuerier(querier config.PgxIface) NomadEventService {
	return &nomadEventService{
		logger:               n.logger,
		nomadEventRepository: n.nomadEventRepository.WithQuerier(querier),
		runService:           n.runService.WithQuerier(querier),
	}
}

func (n *nomadEventService) Save(event *nomad.Event) error {
	n.logger.Debug().Msgf("Saving new NomadEvent %d", event.Index)
	if err := n.nomadEventRepository.Save(event); err != nil {
		return errors.WithMessagef(err, "Could not insert NomadEvent")
	}
	n.logger.Debug().Msgf("Created NomadEvent %d", event.Index)
	return nil
}

func (n *nomadEventService) GetLastNomadEvent() (uint64, error) {
	n.logger.Debug().Msg("Get last Nomad Event")
	return n.nomadEventRepository.GetLastNomadEvent()
}

func (n *nomadEventService) GetEventAllocByNomadJobId(nomadJobId uuid.UUID) (map[string]domain.AllocWrapper, error) {
	allocs := map[string]domain.AllocWrapper{}
	n.logger.Debug().Msgf("Getting EventAlloc by Nomad Job ID: %q", nomadJobId)
	results, err := n.nomadEventRepository.GetEventAllocByNomadJobId(nomadJobId)
	if err != nil {
		return nil, err
	}

	for _, result := range results {
		if result["alloc"] == nil {
			continue
		}

		alloc := &nomad.Allocation{}
		err = json.Unmarshal([]byte(result["alloc"].(string)), alloc)
		if err != nil {
			return nil, err
		}

		run, err := n.runService.GetByNomadJobId(nomadJobId)
		if err != nil {
			return nil, err
		}

		logs := map[string]*domain.LokiOutput{}

		for taskName := range alloc.TaskResources {
			taskLogs, err := n.runService.RunLogs(alloc.ID, alloc.TaskGroup, taskName, run.CreatedAt, run.FinishedAt)
			if err != nil {
				return nil, err
			}
			logs[taskName] = taskLogs
		}

		allocs[alloc.Name] = domain.AllocWrapper{Alloc: alloc, Logs: logs}
	}

	n.logger.Debug().Msgf("Got EventAlloc by Nomad Job ID: %q", nomadJobId)
	return allocs, nil
}
