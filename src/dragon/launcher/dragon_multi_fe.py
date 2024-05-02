#!/usr/bin/env python3

"""Simple multi-node dragon infrastructure startup"""
import os
import logging

from .frontend import LauncherFrontEnd, LAUNCHER_FAIL_EXIT, LAUNCHER_SUCCESS_EXIT
from .launchargs import get_args as get_cli_args

from ..utils import set_procname, set_host_id, host_id
from ..dlogging.util import setup_FE_logging, DragonLoggingServices as dls

from ..infrastructure.facts import PROCNAME_LA_FE, FRONTEND_HOSTID
from ..infrastructure.node_desc import NodeDescriptor

def main(args_map=None):

    if args_map is None:
        args_map = get_cli_args()

    setup_FE_logging(log_device_level_map=args_map['log_device_level_map'],
                     basename='dragon', basedir=os.getcwd())
    log = logging.getLogger(dls.LA_FE).getChild('main')
    log.info(f'start in pid {os.getpid()}, pgid {os.getpgid(0)}')

    # Before doing anything set my host ID
    set_host_id(FRONTEND_HOSTID)
    log.info(f"set host id to {FRONTEND_HOSTID}, and return {host_id()}")

    for key, value in args_map.items():
        if value is not None:
            log.info(f'args_map: {key}: {value}')

    execution_complete = False
    net_conf = None

    while not execution_complete:
        # Try to run the launcher

        try:
            with LauncherFrontEnd(args_map=args_map) as fe_server:
                net_conf = fe_server.run_startup(net_conf=net_conf)
                net_conf = fe_server.run_app()
                net_conf = fe_server.run_msg_server()

        # Handle an obvious exception as well as what to do if we're trying a resilient runtime
        except Exception as err:
            log.exception(f'Error in launcher frontend: {err}')
            if not fe_server.resilient:
                return LAUNCHER_FAIL_EXIT

            # Check if the sum of active and idle nodes is > 0:
            avail_nodes = len([idx for idx, node in net_conf.items()
                               if node.state in [NodeDescriptor.State.ACTIVE, NodeDescriptor.State.IDLE] and idx !='f'])
            log.info(f'avail nodes found to be {avail_nodes}')

            # Proceed
            if args_map['exhaust_resources']:
                if avail_nodes == 0:
                    print("There are no more hardware resources available for continued app execution.")
                    return LAUNCHER_FAIL_EXIT
            elif avail_nodes == args_map['node_count'] - 1:
                print("There are not enough hardware resources available for continued app execution.")
                return LAUNCHER_FAIL_EXIT


        # If everything exited wtihout exception, break out of the loop and exit
        else:
            execution_complete = True

    log.info("exiting frontend")
    return LAUNCHER_SUCCESS_EXIT


if __name__ == "__main__":
    set_procname(PROCNAME_LA_FE)
    ecode = main()
    exit(ecode)
