package k8sutil

import (
	"encoding/json"

	"github.com/astaxie/beego/logs"
	"k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// CreateServiceByJSON create a service by json
func CreateServiceByJSON(j []byte) (*v1.Service, error) {
	srv := &v1.Service{}
	if err := json.Unmarshal(j, srv); err != nil {
		return nil, err
	}
	return CreateService(srv)
}

// CreateService create a service
func CreateService(srv *v1.Service) (*v1.Service, error) {
	retSrv, err := kubecli.CoreV1().Services(Namespace).Create(srv)
	if err != nil {
		return nil, err
	}
	logs.Info(`Service "%s" created`, srv.GetName())

	return retSrv, nil
}

// DelSrvs delete services
func DelSrvs(names ...string) error {
	for _, name := range names {
		kubecli.CoreV1().Services(Namespace).Delete(name, &metav1.DeleteOptions{})
		logs.Info("Service %q deleted", name)
	}
	return nil
}
