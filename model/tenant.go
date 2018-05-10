package model

import (
	"fmt"
	"time"

	"github.com/mickep76/qry"
	"github.com/pborman/uuid"
)

type Tenant struct {
	UUID    string     `json:"uuid"`
	Created time.Time  `json:"created"`
	Updated *time.Time `json:"updated,omitempty"`
	Name    string     `json:"name"`
}

type Tenants []*Tenant

func NewTenant(name string) *Tenant {
	return &Tenant{
		UUID:    uuid.New(),
		Created: time.Now(),
		Name:    name,
	}
}

func (ds *Datastore) QueryTenant(q *qry.Query) (Tenants, error) {
	kvs, err := ds.Values("tenants")
	if err != nil {
		return nil, err
	}

	tenants := Tenants{}
	if err := kvs.Decode(&tenants); err != nil {
		return nil, err
	}

	r, err := q.Eval(tenants)
	if err != nil {
		return nil, err
	}

	return r.(Tenants), nil
}

func (ds *Datastore) OneTenant(uuid string) (*Tenant, error) {
	kvs, err := ds.Values(fmt.Sprintf("tenants/%s", uuid))
	if err != nil {
		return nil, err
	}

	tenants := Tenants{}
	if err := kvs.Decode(&tenants); err != nil {
		return nil, err
	}

	if len(tenants) > 0 {
		return tenants[0], nil
	}

	return nil, nil
}

func (ds *Datastore) CreateTenant(tenant *Tenant) error {
	return ds.Set(fmt.Sprintf("tenants/%s", tenant.UUID), tenant)
}

func (ds *Datastore) UpdateTenant(tenant *Tenant) error {
	now := time.Now()
	tenant.Updated = &now
	return ds.Set(fmt.Sprintf("tenants/%s", tenant.UUID), tenant)
}
