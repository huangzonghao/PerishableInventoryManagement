/*
 * =============================================================================
 *
 *       Filename:  model_dp.cu
 *
 *    Description:  All the functions to compute with the dynamic programming
 *                    algorithm
 *
 *        Created:  Fri Aug  7 23:47:24 2015
 *       Modified:  Wed Aug 26 04:46:43 2015
 *
 *         Author:  Huang Zonghao
 *          Email:  coding@huangzonghao.com
 *
 * =============================================================================
 */
#include "../include/models.h"
__device__ void
optimize(float *current_values,
         size_t current,
         dp_int *depletion,
         int min_depletion,
         int max_depletion,
         dp_int *order,
         int min_order,
         int max_order,
         float *future_values,
         int period) {

    // Allocate a memory buffer on stack
    // So we don't need to do it for every loop
    // Last dimension are used to store the ordering
    // which could be used for sale
    int state[n_dimension+1] = {};
    decode(state, current);

    int n_depletion = 0;
    int n_order = 0;
    float max_value = 0.0;

   // struct Demand demand = demand_distribution_at_period[period];
 struct Demand demand = demand_distribution_at_period[0];

    for (int i = min_depletion; i < max_depletion; i++) {
        for (int j = min_order; j < max_order; j++) {

            float expected_value = 0.0;

            for (int k = demand.min_demand; k < demand.max_demand; k++) {

                // Always initialize state array before calling of revenue()
                // As the value is corrupted and can't be used again
                decode(state, current);

                // By calling revenue(), the state array
                // now stores the state for future
                float value = revenue(state, current, i, j, k);

                // And find the corresponding utility of future
                int future = encode(state);

                value += discount * future_values[future];

                expected_value += demand.distribution[k - demand.min_demand] * value;
            }

            // Simply taking the moving maximum
            if (expected_value > max_value + 1e-6) {
                max_value = expected_value;
                n_depletion = i;
                n_order = j;
            }
        }
    }

    // Store the optimal point and value
    current_values[current] = max_value;
    depletion[current] = (dp_int) n_depletion;
    order[current] = (dp_int) n_order;
}
/*
 * ===  GLOBAL KERNEL  =========================================================
 *         Name:  g_ModelDPInit
 *  Description:  init the DP table with the tree structrue
 *       @param:  current table, the index of the current level index, the total
 *                   number of states contained in this level and the batch index
 *                   for the current level (how many turns that the kernel has
 *                   been working on this level)
 * =============================================================================
 */

/* :REMARKS:Tue Aug 25 19:28:15 2015:huangzonghao:
 *  for each level, we are gonna calculate from the 1 to k for some digit
 */
__global__
void g_ModelDPInit(float *current_table, size_t batchIdx, size_t level_size ){
    /* myIdx is the index of the current state within each level */
    size_t myIdx = threadIdx.x + blockIdx.x * blockDim.x;
    if ( myIdx < level_size ){
        size_t current_data_idx = batchIdx * level_size + myIdx;
        size_t parent_data_idx = current_data_idx - level_size;
        if(current_data_idx == 0){
            current_table[current_data_idx] = 0.0;
        }
        else {
            current_table[current_data_idx] = current_table[parent_data_idx] + 1;
        }
    }
    return;
}       /* -----  end of global kernel g_ModelDPInit  ----- */

/*
 * ===  FUNCTION  ==============================================================
 *         Name:  ModelDPInit
 *  Description:  The initialization function for ModelDP
                      to calculate all the state value from the boundary conditions
 *       @param:  the control sequence, the system information
 *      @return:  success or not
 * =============================================================================
 */
bool ModelDPInit(CommandQueue * cmd, SystemInfo * sysinfo, float *value_table){
    /* the first layer with level zero and level size one */
    g_ModelDPInit<<<1,1>>>(value_table, 0, 1);
    /* then the each level just get larger and larger */
    size_t level_size;
    size_t num_blocks_used;
    size_t core_size = sysinfo->get_value("core_size");
    for(int i_level = 0; i_level < cmd->get_h_params("m"); ++i_level){
        level_size = pow(cmd->get_h_params("m"), i_level);
        num_blocks_used = level_size / core_size + 1;
        for(int i_batch = 1; i_batch < cmd->get_h_params("k"); ++i_batch){
            g_ModelDPInit<<<num_blocks_used, core_size>>>(value_table,
                                                          i_batch,
                                                          level_size);
        }
    }
    return true;
}       /* -----  end of function ModelDPInit  ----- */

/*
 * ===  GLOBAL KERNEL  =========================================================
 *         Name:  g_ModelDP
 *  Description:  the kernel function for the tree structure
 *       @param:  table to update, table for reference, amount to deplete, amount
 *                   to order, the total number of states of this level the
 *                   batch index(the value of the digit we are updating within
 *                   certain level)
 * =============================================================================
 */
__global__
void g_ModelDP(float *table_to_update,
               float *table_for_reference,
               int *z,
               int *q,
               size_t k,
               size_t level_size,
               size_t batchIdx){

    size_t myIdx = threadIdx.x + blockIdx.x * blockDim.x;

    if (myIdx < level_size) {

        size_t current = batch_idx * level_size + myIdx;
        size_t parent = current - level_size;

        if (current == 0 || depletion[parent] == 0) {
            optimize(table_to_update,
                    // the state we are computing
                    current,
                    // n_depletion, min_depletion, max_depletion
                    z, 0, 2,
                    // n_order, min_order, max_order
                    q, 0, k,
                    // future utility for reference
                    table_for_reference);

        } else /* (depletion[parent] != 0) */ {
            optimize(table_to_update,
                    // the state we are computing
                    current,
                    // n_depletion, min_depletion, max_depletion
                    z, z[parent]+1, z[parent]+2,
                    // n_order, min_order, max_order
                    q, q[parent], q[parent]+1,
                    // future utility for reference
                    table_for_reference);

        }
    }
    return;
}       /* -----  end of global kernel g_ModelDP  ----- */
/*
 * ===  FUNCTION  ==============================================================
 *         Name:  ModelDP
 *  Description:  to update the table for one period with the dynamic programming
 *                  algorithm
 *       @param:  control sequence, system information, the index of the period
 *      @return:  success or not
 * =============================================================================
 */
bool ModelDP(CommandQueue * cmd,
             SystemInfo * sysinfo,
             float *table_to_update,
             float *table_for_reference,
             int *z,
             int *q){

    size_t level_size = std::pow(cmd->get_h_params("k"), cmd->get_h_params("m"));
    // The very first state 0,0,...,0
    g_ModelDP<<<1, 1>>>(  table_to_update,
                          table_for_reference,
                          z,
                          q,
                          k,
                          1,
                          0
                        );

    size_t num_blocks_used;
    size_t core_size = sysinfo->get_value("core_size");
    for (size_t i_level = 0; i_level < cmd->get_h_params("m"); ++i_level) {
        num_blocks_used = i_level * cmd->get_h_params("k");
        for (size_t i_batch = 1; i_batch < n_capacity; i_batch++) {
            g_ModelDP<<<num_blocks_used, core_size >>>(  table_to_update,
                                                         table_for_reference,
                                                         z,
                                                         q,
                                                         k,
                                                         i_batch,
                                                         level_size);
        }
    }
    return true;
}       /* -----  end of function ModelDP  ----- */


/* =============================================================================
 *                         end of file model_dp.cu
 * =============================================================================
 */
